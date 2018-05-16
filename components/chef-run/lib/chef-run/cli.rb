#
# Copyright:: Copyright (c) 2018 Chef Software Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
require "mixlib/cli"
require "chef/log"
require "chef-config/config"
require "chef-config/logger"
require "chef-run/target_host"
require "chef-run/action/install_chef"
require "chef-run/action/converge_target"
require "chef-run/config"
require "chef-run/error"
require "chef-run/log"
require "chef-run/recipe_lookup"
require "chef-run/target_resolver"
require "chef-run/temp_cookbook"
require "chef-run/text"
require "chef-run/ui/error_printer"
require "chef-run/version"

module ChefRun
  class CLI
    include Mixlib::CLI
    T = ChefRun::Text.cli
    TS = ChefRun::Text.status
    RC_COMMAND_FAILED = 1
    RC_ERROR_HANDLING_FAILED = 64

    banner "Command banner not set."

    option :version,
      :short        => "-v",
      :long         => "--version",
      :description  => T.version.description,
      :boolean      => true

    option :help,
      :short        => "-h",
      :long         => "--help",
      :description  => T.help.description,
      :boolean      => true

    option :config_path,
      :short        => "-c PATH",
      :long         => "--config PATH",
      :description  => T.default_config_location(ChefRun::Config.default_location),
      :default      => ChefRun::Config.default_location,
      :proc         => Proc.new { |path| ChefRun::Config.custom_location(path) }

    option :root,
      :long => "--[no-]root",
      :description => T.root_description,
      :boolean => true,
      :default => true

    option :identity_file,
      :long => "--identity-file PATH",
      :short => "-i PATH",
      :description => T.identity_file,
      :proc => (Proc.new do |path|
        unless File.exist?(path)
          raise OptionValidationError.new("CHEFVAL001", self, path)
        end
        path
      end)

    option :ssl,
      :long => "--[no-]ssl",
      :short => "-s",
      :description => T.ssl.desc(ChefRun::Config.connection.winrm.ssl),
      :boolean => true,
      :default => ChefRun::Config.connection.winrm.ssl

    option :ssl_verify,
      :long => "--[no-]ssl-verify",
      :short => "-s",
      :description => T.ssl.verify_desc(ChefRun::Config.connection.winrm.ssl_verify),
      :boolean => true,
      :default => ChefRun::Config.connection.winrm.ssl_verify

    option :cookbook_repo_paths,
      :long => "--cookbook-repo-paths PATH",
      :description => T.cookbook_repo_paths,
      :default => ChefRun::Config.chef.cookbook_repo_paths,
      :proc => Proc.new { |paths| paths.split(",") }

    option :install,
       long: "--[no-]install",
       default: true,
       boolean: true,
       description:  T.install_description(Action::InstallChef::Base::MIN_CHEF_VERSION)

    def initialize(argv)
      @argv = argv
      @rc = 0
      super()
    end

    def run
      setup_cli
      parse_options(@argv)
      if @argv.empty? || config[:help]
        show_help
      elsif config[:version]
       show_version
      else
        perform_run
      end
    rescue WrappedError => e
      UI::ErrorPrinter.show_error(e)
      @rc = RC_COMMAND_FAILED
    rescue SystemExit => e
      @rc = e.status
    rescue => e
      UI::ErrorPrinter.dump_unexpected_error(e)
      @rc = RC_ERROR_HANDLING_FAILED
    ensure
      exit @rc
    end

    # private
    def setup_cli
      # Enable CLI output via Terminal. This comes first because we want to supply
      # status output about reading and creating config files
      UI::Terminal.init($stdout)
      if Config.using_default_location? && !Config.exist?
        UI::Terminal.output T.creating_config(Config.default_location)
        Config.create_default_config_file
      end
      Config.load
      ChefRun::Log.setup(Config.log.location, Config.log.level.to_sym)
      ChefRun::Log.info("Initialized logger")
    end

    def perform_run
      validate_params(cli_arguments)
      configure_chef
      target_hosts = TargetResolver.new(cli_arguments.shift, config).targets
      temp_cookbook, initial_status_msg = generate_temp_cookbook(cli_arguments)
      if target_hosts.length == 1
        run_single_target(initial_status_msg, target_hosts[0], temp_cookbook )
      else
        @multi_target = true
        run_multi_target(initial_status_msg, target_hosts, temp_cookbook)
      end
    rescue => e
      handle_perform_error(e)
    end

    # Accepts a target_host and establishes the connection to that host
    # while providing visual feedback via the Terminal API.
    def connect_target(target_host, reporter = nil)
      if reporter.nil?
        UI::Terminal.render_job(T.status.connecting, prefix: "[#{target_host.config[:host]}]") do |rep|
          target_host.connect!
          rep.success(T.status.connected)
        end
      else
        reporter.update(T.status.connecting)
        target_host.connect!
        # No success here - if we have a reporter,
        # it's because it will be used for more actions than our own
        # and success marks the end.
        reporter.update(T.status.connected)
      end
      target_host
    rescue StandardError => e
      if reporter.nil?
        UI::Terminal.output(e.message)
      else
        reporter.error(e.message)
      end
      raise
    end

    def run_single_target(initial_status_msg, target_host, temp_cookbook)
      connect_target(target_host)
      prefix = "[#{target_host.hostname}]"
      UI::Terminal.render_job(TS.install_chef.verifying, prefix: prefix) do |reporter|
        install(target_host, reporter)
      end
      UI::Terminal.render_job(initial_status_msg, prefix: "[#{target_host.hostname}]") do |reporter|
        converge(reporter, temp_cookbook, target_host)
      end
    end

    def run_multi_target(initial_status_msg, target_hosts, temp_cookbook)
      # Our multi-host UX does not show a line item per action,
      # but rather a line-item per connection.
      jobs = target_hosts.map do |target_host|
        # This block will run in its own thread during render.
        UI::Terminal::Job.new("[#{target_host.hostname}]", target_host) do |reporter|
          connect_target(target_host, reporter)
          reporter.update(TS.install_chef.verifying)
          install(target_host, reporter)
          reporter.update(initial_status_msg)
          converge(reporter, temp_cookbook, target_host)
        end
      end
      UI::Terminal.render_parallel_jobs(TS.converge.multi_header, jobs)
      handle_job_failures(jobs)
    end

    # The first param is always hostname. Then we either have
    # 1. A recipe designation
    # 2. A resource type and resource name followed by any properties
    PROPERTY_MATCHER = /^([a-zA-Z0-9_]+)=(.+)$/
    CB_MATCHER = '[\w\-]+'
    def validate_params(params)
      if params.size < 2
        raise OptionValidationError.new("CHEFVAL002", self)
      end
      if params.size == 2
        # Trying to specify a recipe to run remotely, no properties
        cb = params[1]
        if File.exist?(cb)
          # This is a path specification, and we know it is valid
        elsif cb =~ /^#{CB_MATCHER}$/ || cb =~ /^#{CB_MATCHER}::#{CB_MATCHER}$/
          # They are specifying a cookbook as 'cb_name' or 'cb_name::recipe'
        else
          raise OptionValidationError.new("CHEFVAL004", self, cb)
        end
      elsif params.size >= 3
        properties = params[3..-1]
        properties.each do |property|
          unless property =~ PROPERTY_MATCHER
            raise OptionValidationError.new("CHEFVAL003", self, property)
          end
        end
      end
    end

    # Now that we are leveraging Chef locally we want to perform some initial setup of it
    def configure_chef
      ChefConfig.logger = ChefRun::Log
      # Setting the config isn't enough, we need to ensure the logger is initialized
      # or automatic initialization will still go to stdout
      Chef::Log.init(ChefRun::Log)
      Chef::Log.level = ChefRun::Log.level
    end

    def format_properties(string_props)
      properties = {}
      string_props.each do |a|
        key, value = PROPERTY_MATCHER.match(a)[1..-1]
        value = transform_property_value(value)
        properties[key] = value
      end
      properties
    end

      # Incoming properties are always read as a string from the command line.
      # Depending on their type we should transform them so we do not try and pass
      # a string to a resource property that expects an integer or boolean.
    def transform_property_value(value)
      case value
      when /^0/
        # when it is a zero leading value like "0777" don't turn
        # it into a number (this is a mode flag)
        value
      when /^\d+$/
        value.to_i
      when /(^(\d+)(\.)?(\d+)?)|(^(\d+)?(\.)(\d+))/
        value.to_f
      when /true/i
        true
      when /false/i
        false
      else
        value
      end
    end

    # The user will either specify a single resource on the command line, or a recipe.
    # We need to parse out those two different situations
    def generate_temp_cookbook(cli_arguments)
      temp_cookbook = TempCookbook.new
      if recipe_strategy?(cli_arguments)
        recipe_specifier = cli_arguments.shift
        ChefRun::Log.debug("Beginning to look for recipe specified as #{recipe_specifier}")
        if File.file?(recipe_specifier)
          ChefRun::Log.debug("#{recipe_specifier} is a valid path to a recipe")
          recipe_path = recipe_specifier
        else
          rl = RecipeLookup.new(config[:cookbook_repo_paths])
          cookbook_path_or_name, optional_recipe_name = rl.split(recipe_specifier)
          cookbook = rl.load_cookbook(cookbook_path_or_name)
          recipe_path = rl.find_recipe(cookbook, optional_recipe_name)
        end
        temp_cookbook.from_existing_recipe(recipe_path)
        initial_status_msg = TS.converge.converging_recipe(recipe_specifier)
      else
        resource_type = cli_arguments.shift
        resource_name = cli_arguments.shift
        temp_cookbook.from_resource(resource_type, resource_name, format_properties(cli_arguments))
        full_rs_name = "#{resource_type}[#{resource_name}]"
        ChefRun::Log.debug("Converging resource #{full_rs_name} on target")
        initial_status_msg = TS.converge.converging_resource(full_rs_name)
      end

      [temp_cookbook, initial_status_msg]
    end

    def recipe_strategy?(cli_arguments)
      cli_arguments.size == 1
    end

    # Runs the InstallChef action and renders UI updates as
    # the action reports back
    def install(target_host, reporter)
      installer = Action::InstallChef.instance_for_target(target_host, check_only: !config[:install])
      context = TS.install_chef
      installer.run do |event, data|
        case event
        when :installing
          if installer.upgrading?
            message = context.upgrading(target_host.installed_chef_version, installer.version_to_install)
          else
            message = context.installing(installer.version_to_install)
          end
          reporter.update(message)
        when :uploading
          reporter.update(context.uploading)
        when :downloading
          reporter.update(context.downloading)
        when :already_installed
          meth = @multi_target ? :update : :success
          reporter.send(meth, context.already_present(target_host.installed_chef_version))
        when :install_complete
          meth = @multi_target ? :update : :success
          if installer.upgrading?
            message = context.upgrade_success(target_host.installed_chef_version, installer.version_to_install)
          else
            message = context.install_success(installer.version_to_install)
          end
          reporter.send(meth, message)
        else
          handle_message(event, data, reporter)
        end
      end
    end

    # Runs the Converge action and renders UI updates as
    # the action reports back
    def converge(reporter, temp_cookbook, target_host)
      converge_args = { local_cookbook: temp_cookbook, target_host: target_host }
      converger = Action::ConvergeTarget.new(converge_args)
      converger.run do |event, data|
        case event
        when :success
          reporter.success(TS.converge.success)
        when :converge_error
          reporter.error(TS.converge.failure)
        when :creating_remote_policy
          reporter.update(TS.converge.creating_remote_policy)
        when :running_chef
          reporter.update(TS.converge.running_chef)
        when :reboot
          reporter.success(TS.converge.reboot)
        else
          handle_message(event, data, reporter)
        end
      end
      temp_cookbook.delete
    end

    def handle_perform_error(e)
      id = e.respond_to?(:id) ? e.id : e.class.to_s
      message = e.respond_to?(:message) ? e.message : e.to_s
      # Telemetry.capture(:error, exception: { id: id, message: message })
      wrapper = ChefRun::StandardErrorResolver.wrap_exception(e)
      capture_exception_backtrace(wrapper)
      # Now that our housekeeping is done, allow user-facing handling/formatting
      # in `run` to execute by re-raising
      raise wrapper
    end

    # When running multiple jobs, exceptions are captured to the
    # job to avoid interrupting other jobs in process.  This function
    # collects them and raises a MultiJobFailure if failure has occurred;
    # we do *not* differentiate between one failed jobs and multiple failed jobs
    # - if you're in the 'multi-job' path (eg, multiple targets) we handle
    # all errors the same to provide a consistent UX when running with mulitiple targets.
    def handle_job_failures(jobs)
      failed_jobs = jobs.select { |j| !j.exception.nil? }
      return if failed_jobs.empty?
      raise ChefRun::MultiJobFailure.new(failed_jobs)
    end

    # A handler for common action messages
    def handle_message(message, data, reporter)
      if message == :error # data[0] = exception
        # Mark the current task as failed with whatever data is available to us
        require "chef-run/ui/error_printer"
        reporter.error(ChefRun::UI::ErrorPrinter.error_summary(data[0]))
      end
    end

    def capture_exception_backtrace(e)
      UI::ErrorPrinter.write_backtrace(e, @argv)
    end

    def show_help
      UI::Terminal.output "#{T.description}\n#{T.usage_full}"
    end

    def usage
      T.usage
    end

    def show_version
      UI::Terminal.output T.version.show(ChefRun::VERSION)
    end

    class OptionValidationError < ChefRun::ErrorNoLogs
      attr_reader :command
      def initialize(id, calling_command, *args)
        super(id, *args)
        # TODO - this is getting cumbersome - move them to constructor options hash in base
        @decorate = false
        @command = calling_command
      end
    end
  end
end
