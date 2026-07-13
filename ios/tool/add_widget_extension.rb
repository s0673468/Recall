#!/usr/bin/env ruby
# frozen_string_literal: true

# Reproducibly wires Recall's aggregate-only WidgetKit extension into the
# checked-in Flutter Xcode project. Safe to re-run after `flutter create` or an
# Xcode project refresh.

require 'xcodeproj'

ios_dir = File.expand_path('..', __dir__)
project = Xcodeproj::Project.open(File.join(ios_dir, 'Runner.xcodeproj'))

ext_name = 'RecallWidget'
ext_bundle_id = 'com.german.ankiReview.RecallWidget'
runner = project.targets.find { |target| target.name == 'Runner' }
raise 'Runner target not found' unless runner

runner.build_configurations.each do |configuration|
  configuration.build_settings['CODE_SIGN_ENTITLEMENTS'] =
    'Runner/Runner.entitlements'
end

runner_group = project.main_group['Runner']
raise 'Runner group not found' unless runner_group

{
  'Runner.entitlements' => false,
  'RecallWidgetPlugin.swift' => true,
}.each do |filename, add_to_sources|
  reference = runner_group.files.find { |file| file.display_name == filename }
  reference ||= runner_group.new_reference(filename)
  if add_to_sources && !runner.source_build_phase.files_references.include?(reference)
    runner.source_build_phase.add_file_reference(reference)
  end
end

extension = project.targets.find { |target| target.name == ext_name }
unless extension
  # OpenURLIntent is the safe, explicit App-Intent-to-deep-link bridge and is
  # available from iOS 18. The containing app itself continues to support 16+.
  extension = project.new_target(:app_extension, ext_name, :ios, '18.0')
end

widget_group = project.main_group[ext_name]
widget_group ||= project.main_group.new_group(ext_name, ext_name)
widget_references = {}
[
  "#{ext_name}.swift",
  'Info.plist',
  "#{ext_name}.entitlements",
].each do |filename|
  widget_references[filename] =
    widget_group.files.find { |file| file.display_name == filename } ||
    widget_group.new_reference(filename)
end
swift = widget_references.fetch("#{ext_name}.swift")
unless extension.source_build_phase.files_references.include?(swift)
  extension.source_build_phase.add_file_reference(swift)
end

%w[WidgetKit SwiftUI AppIntents].each do |framework|
  next if extension.frameworks_build_phase.files_references.any? do |reference|
    reference.display_name == "#{framework}.framework"
  end
  extension.add_system_framework(framework)
end

# xcodeproj's add_system_framework pins the currently installed iPhoneOS SDK
# version into the file reference. Normalize every extension framework to
# SDKROOT so a later Xcode can resolve its own installed SDK.
system_framework_names = %w[Foundation WidgetKit SwiftUI AppIntents]
project.objects.grep(Xcodeproj::Project::Object::PBXFileReference).each do |reference|
  next unless system_framework_names.include?(File.basename(reference.path.to_s, '.framework'))

  name = File.basename(reference.path.to_s)
  reference.name = name
  reference.path = "System/Library/Frameworks/#{name}"
  reference.source_tree = 'SDKROOT'
end

embed = runner.copy_files_build_phases.find do |phase|
  phase.symbol_dst_subfolder_spec == :plug_ins
end
unless embed
  embed = runner.new_copy_files_build_phase('Embed App Extensions')
  embed.symbol_dst_subfolder_spec = :plug_ins
  embed.dst_path = ''
end
unless embed.files_references.include?(extension.product_reference)
  embed.add_file_reference(extension.product_reference, true)
end
# Flutter's Thin Binary phase reads the finished containing bundle. Xcode 15+
# forms a dependency cycle if the extension copy phase sits after it.
thin_binary = runner.shell_script_build_phases.find do |phase|
  phase.name == 'Thin Binary'
end
if thin_binary
  runner.build_phases.delete(embed)
  runner.build_phases.insert(runner.build_phases.index(thin_binary), embed)
end
runner.add_dependency(extension) unless runner.dependencies.any? do |dependency|
  dependency.target == extension
end

# Keep target settings canonical even when repairing an existing project.
extension.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  settings['CODE_SIGN_ENTITLEMENTS'] =
    "#{ext_name}/#{ext_name}.entitlements"
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['CURRENT_PROJECT_VERSION'] = '1'
  settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  settings['INFOPLIST_FILE'] = "#{ext_name}/Info.plist"
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = '18.0'
  settings['LD_RUNPATH_SEARCH_PATHS'] =
    '$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'
  settings['MARKETING_VERSION'] = '1.0.0'
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = ext_bundle_id
  settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
  settings['SKIP_INSTALL'] = 'YES'
  settings['SWIFT_EMIT_LOC_STRINGS'] = 'YES'
  settings['SWIFT_VERSION'] = '5.0'
  settings['TARGETED_DEVICE_FAMILY'] = '1'
end

project.save
puts 'Recall WidgetKit extension is wired.'
