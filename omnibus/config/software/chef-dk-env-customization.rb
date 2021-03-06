#
# Copyright:: Copyright (c) 2015-2018, Chef Software Inc.
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

# This is a windows only dependency

name "chef-dk-env-customization"

skip_transitive_dependency_licensing true
license :project_license

source path: "#{project.files_path}/#{name}"

dependency "ruby"

build do
  # lazied because we need ruby to get installed first
  block "Add chefdk_env_customization file" do
    source_customization_file = "#{project_dir}/windows/chefdk_env_customization.rb"

    site_ruby = Bundler.with_clean_env do
      ruby = windows_safe_path("#{install_dir}/embedded/bin/ruby")
      `#{ruby} -rrbconfig -e "puts RbConfig::CONFIG['sitelibdir']"`.strip
    end

    if site_ruby.nil? || site_ruby.empty?
      raise "Could not determine embedded Ruby's site directory, aborting!"
    end

    create_directory site_ruby
    copy_file source_customization_file, site_ruby
  end
end
