#!/usr/bin/env ruby
# frozen_string_literal: true

# Removes only the App-Group-dependent widget from a disposable /tmp copy of
# the Xcode project. Apple's free Personal Team cannot provision App Groups;
# the main app (haptics, reminders, background outbox sync, native shell) can
# still be signed and installed. Never run this against the checked-in project.

require 'xcodeproj'

project_path = if ARGV[0]
                 File.expand_path(ARGV[0], Dir.pwd)
               else
                 File.expand_path('../Runner.xcodeproj', __dir__)
               end
unless project_path.start_with?('/private/tmp/', '/tmp/')
  abort 'Refusing to modify a non-temporary Xcode project.'
end

project = Xcodeproj::Project.open(project_path)
runner = project.targets.find { |target| target.name == 'Runner' }
widget = project.targets.find { |target| target.name == 'RecallWidget' }
abort 'Runner target not found.' unless runner

if widget
  runner.dependencies
        .select { |dependency| dependency.target == widget }
        .each(&:remove_from_project)
  runner.copy_files_build_phases.each do |phase|
    phase.files
         .select { |file| file.file_ref == widget.product_reference }
         .each(&:remove_from_project)
  end
  widget.remove_from_project
end

runner.build_configurations.each do |configuration|
  configuration.build_settings.delete('CODE_SIGN_ENTITLEMENTS')
end

project.save
puts 'Prepared temporary Personal Team build (RecallWidget omitted).'
