# frozen_string_literal: true

require "autoproj/workspace"
require "autoproj/cli/update"

module Autoproj
    module Daemon
        # This class updates the given workspace.
        # It is also responsible for restarting the daemon
        # and tracking update status.
        class WorkspaceUpdater
            # @return [Autoproj::Workspace]
            attr_reader :ws

            # @param [Autoproj::Workspace] workspace
            def initialize(workspace)
                @ws = workspace
                @update_failed = false
            end

            # Whether an attempt to update the workspace has failed
            #
            # @return [Time]
            def update_failed?
                @update_failed
            end

            # Updates the current workspace. This method will invoke the CLI
            # (same as doing an 'autoproj update --no-interactive --no-osdeps').
            # The member variable @update_failed will store the result of the
            # update attempt.
            #
            # @return [Boolean] whether the update failed or not
            def update
                ws.config.interactive = false
                Autoproj::CLI::Update.new(ws).run(
                    [], reset: :force,
                        packages: true,
                        config: true,
                        deps: true,
                        osdeps_filter_uptodate: true,
                        osdeps: false
                )
                @update_failed = false
                true
            rescue StandardError => e
                # if this is true, the only thing the daemon
                # should do is update the workspace on push events,
                # no PR syncing and no triggering of builds
                # on PR events
                @update_failed = Time.now
                Autoproj.error e.message
                false
            end

            # @return [void]
            def restart_and_update
                Process.exec(
                    Gem.ruby, $PROGRAM_NAME, "daemon", "start", "--update"
                )
            end
        end
    end
end
