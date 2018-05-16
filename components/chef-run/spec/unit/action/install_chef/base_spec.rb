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

require "spec_helper"
require "chef-run/action/install_chef"

RSpec.describe ChefRun::Action::InstallChef::Base do
  let(:mock_os_name) { "mock" }
  let(:mock_os_family) { "mock" }
  let(:mock_os_release ) { "unknown" }
  let(:mock_opts) do
    {
      name: mock_os_name,
      family: mock_os_family,
      release: mock_os_release,
      arch: "x86_64",
    }
  end
  let(:target_host) do
    ChefRun::TargetHost.new("mock://user1:password1@localhost")
  end

  let(:reporter) do
    ChefRun::MockReporter.new
  end

  subject(:install) do
    ChefRun::Action::InstallChef::Base.new(target_host: target_host,
                                           reporter: reporter) end
  before do
    target_host.connect!
    target_host.backend.mock_os(mock_opts)
  end

  context "#perform_action" do
    context "when chef is already installed on target at the correct minimum version" do
      before do
        expect(install.target_host).to receive(:installed_chef_version).and_return ChefRun::Action::InstallChef::Base::MIN_CHEF_VERSION
      end
      it "notifies of success and takes no further action" do
        expect(install).not_to receive(:perform_local_install)
        install.perform_action
      end
    end

    context "when chef is already installed on target at a version that's too low" do
      before do
        expect(install.target_host).to receive(:installed_chef_version).
          and_return Gem::Version.new("12.1.1")
      end
      # 2018-05-10  pended until we determine how we want auto-upgrades to behave
      xit "performs the upgrade" do
        expect(install).to receive(:perform_local_install)
        install.perform_action
      end
    end

    context "when chef is not already installed on target" do
      before do
        expect(install.target_host).to receive(:installed_chef_version).
          and_raise ChefRun::TargetHost::ChefNotInstalled.new
      end

      context "on windows" do
        let(:mock_os_name) { "Windows_Server" }
        let(:mock_os_family) { "windows" }
        let(:mock_os_releae) { "10.0.1" }

        it "should invoke perform_local_install" do
          expect(install).to receive(:perform_local_install)
          install.perform_action
        end
      end

      context "on anything else" do
        let(:mock_os_name) { "Ubuntu" }
        let(:mock_os_family) { "debian" }
        it "should invoke perform_local_install" do
          expect(install).to receive(:perform_local_install)
          install.perform_action
        end
      end
    end
  end
  context "#perform_local_install" do
    let(:artifact) { double("artifact") }
    let(:package_url) { "https://chef.io/download/package/here" }
    before do
      allow(artifact).to receive(:url).and_return package_url
    end

    it "performs the steps necessary to perform an installation" do
      expect(install).to receive(:lookup_artifact).and_return artifact
      expect(install).to receive(:download_to_workstation).with(package_url) .and_return "/local/path"
      expect(install).to receive(:upload_to_target).with("/local/path").and_return("/remote/path")
      expect(install).to receive(:install_chef_to_target).with("/remote/path")

      install.perform_local_install
    end
  end
end
