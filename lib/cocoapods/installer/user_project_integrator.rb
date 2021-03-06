require 'xcodeproj/workspace'
require 'xcodeproj/project'

require 'active_support/core_ext/string/inflections'
require 'active_support/core_ext/array/conversions'

module Pod
  class Installer
    # The {UserProjectIntegrator} integrates the libraries generated by
    # TargetDefinitions of the {Podfile} with their correspondent user
    # projects.
    #
    class UserProjectIntegrator
      autoload :TargetIntegrator, 'cocoapods/installer/user_project_integrator/target_integrator'

      # @return [Podfile] the podfile that should be integrated with the user
      #         projects.
      #
      attr_reader :podfile

      # @return [Project] the pods project which contains the libraries to
      #         integrate.
      #
      # attr_reader :pods_project

      attr_reader :sandbox

      # @return [Pathname] the path of the installation.
      #
      # @todo This is only used to compute the workspace path in case that it
      #       should be inferred by the project. If the workspace should be in
      #       the same dir of the project, this could be removed.
      #
      attr_reader :installation_root

      # @return [Array<AggregateTarget>] the targets represented in the Podfile.
      #
      attr_reader :targets

      # Init a new UserProjectIntegrator
      #
      # @param  [Podfile]  podfile @see #podfile
      # @param  [Sandbox]  sandbox @see #sandbox
      # @param  [Pathname] installation_root @see #installation_root
      # @param  [Array<AggregateTarget>]  targets @see #targets
      #
      # @todo   Too many initialization arguments
      #
      def initialize(podfile, sandbox, installation_root, targets)
        @podfile = podfile
        @sandbox = sandbox
        @installation_root = installation_root
        @targets = targets
      end

      # Integrates the user projects associated with the {TargetDefinitions}
      # with the Pods project and its products.
      #
      # @return [void]
      #
      def integrate!
        create_workspace
        integrate_user_targets
        warn_about_empty_podfile
        warn_about_xcconfig_overrides
      end

      #-----------------------------------------------------------------------#

      private

      # @!group Integration steps

      # Creates and saved the workspace containing the Pods project and the
      # user projects, if needed.
      #
      # @note If the workspace already contains the projects it is not saved
      #       to avoid Xcode from displaying the revert dialog: `Do you want to
      #       keep the Xcode version or revert to the version on disk?`
      #
      # @return [void]
      #
      def create_workspace
        all_projects = user_project_paths.sort.push(sandbox.project_path).uniq
        file_references = all_projects.map do |path|
          relative_path = path.relative_path_from(workspace_path.dirname).to_s
          Xcodeproj::Workspace::FileReference.new(relative_path, 'group')
        end

        if workspace_path.exist?
          workspace = Xcodeproj::Workspace.new_from_xcworkspace(workspace_path)
          new_file_references = file_references - workspace.file_references
          unless new_file_references.empty?
            workspace.file_references.concat(new_file_references)
            workspace.save_as(workspace_path)
          end

        else
          UI.notice "Please close any current Xcode sessions and use `#{workspace_path.basename}` for this project from now on."
          workspace = Xcodeproj::Workspace.new(*file_references)
          workspace.save_as(workspace_path)
        end
      end

      # Integrates the targets of the user projects with the libraries
      # generated from the {Podfile}.
      #
      # @note   {TargetDefinition} without dependencies are skipped prevent
      #         creating empty libraries for targets definitions which are only
      #         wrappers for others.
      #
      # @return [void]
      #
      def integrate_user_targets
        targets_to_integrate.sort_by(&:name).each do |target|
          TargetIntegrator.new(target).integrate!
        end
      end

      # Warns the user if the podfile is empty.
      #
      # @note   The workspace is created in any case and all the user projects
      #         are added to it, however the projects are not integrated as
      #         there is no way to discern between target definitions which are
      #         empty and target definitions which just serve the purpose to
      #         wrap other ones. This is not an issue because empty target
      #         definitions generate empty libraries.
      #
      # @return [void]
      #
      def warn_about_empty_podfile
        if podfile.target_definitions.values.all?(&:empty?)
          UI.warn '[!] The Podfile does not contain any dependencies.'
        end
      end

      IGNORED_KEYS = %w(CODE_SIGN_IDENTITY).freeze
      INHERITED_FLAGS = %w($(inherited) ${inherited}).freeze

      # Checks whether the settings of the CocoaPods generated xcconfig are
      # overridden by the build configuration of a target and prints a
      # warning to inform the user if needed.
      #
      def warn_about_xcconfig_overrides
        targets.each do |aggregate_target|
          aggregate_target.user_targets.each do |user_target|
            user_target.build_configurations.each do |config|
              xcconfig = aggregate_target.xcconfigs[config.name]
              if xcconfig
                (xcconfig.to_hash.keys - IGNORED_KEYS).each do |key|
                  target_values = config.build_settings[key]
                  if target_values &&
                      !INHERITED_FLAGS.any? { |flag| target_values.include?(flag) }
                    print_override_warning(aggregate_target, user_target, config, key)
                  end
                end
              end
            end
          end
        end
      end

      private

      # @!group Private Helpers
      #-----------------------------------------------------------------------#

      # @return [Pathname] the path where the workspace containing the Pods
      #         project and the user projects should be saved.
      #
      def workspace_path
        if podfile.workspace_path
          declared_path = podfile.workspace_path
          path_with_ext = File.extname(declared_path) == '.xcworkspace' ? declared_path : "#{declared_path}.xcworkspace"
          podfile_dir   = File.dirname(podfile.defined_in_file || '')
          absolute_path = File.expand_path(path_with_ext, podfile_dir)
          Pathname.new(absolute_path)
        elsif user_project_paths.count == 1
          project = user_project_paths.first.basename('.xcodeproj')
          installation_root + "#{project}.xcworkspace"
        else
          raise Informative, 'Could not automatically select an Xcode ' \
            "workspace. Specify one in your Podfile like so:\n\n"       \
            "    workspace 'path/to/Workspace.xcworkspace'\n"
        end
      end

      # @return [Array<Pathname>] the paths of all the user projects referenced
      #         by the target definitions.
      #
      # @note   Empty target definitions are ignored.
      #
      def user_project_paths
        targets.map(&:user_project_path).compact.uniq
      end

      def targets_to_integrate
        targets.reject { |target| target.target_definition.empty? }
      end

      # Prints a warning informing the user that a build configuration of
      # the integrated target is overriding the CocoaPods build settings.
      #
      # @param  [Target::AggregateTarget] aggregate_target
      #         The umbrella target.
      #
      # @param  [XcodeProj::PBXNativeTarget] user_target
      #         The native target.
      #
      # @param  [Xcodeproj::XCBuildConfiguration] config
      #         The build configuration.
      #
      # @param  [String] key
      #         The key of the overridden build setting.
      #
      def print_override_warning(aggregate_target, user_target, config, key)
        actions = [
          'Use the `$(inherited)` flag, or',
          'Remove the build settings from the target.',
        ]
        message = "The `#{user_target.name} [#{config.name}]` " \
          "target overrides the `#{key}` build setting defined in " \
          "`#{aggregate_target.xcconfig_relative_path(config.name)}'. " \
          'This can lead to problems with the CocoaPods installation'
        UI.warn(message, actions)
      end

      #-----------------------------------------------------------------------#
    end
  end
end
