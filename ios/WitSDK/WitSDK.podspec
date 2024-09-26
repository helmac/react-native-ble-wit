Pod::Spec.new do |s|
 s.name = 'WitSDK'
 s.version = '1.0.1'
 s.summary = 'WitSDK'
 s.description = 'Wit SKD BLE framework'
 s.license = { :type => 'MIT', :file => 'LICENSE' }
 s.homepage = 'https://github.com/helmac/witsdk'
 s.author = { 'Your Name' => 'rodriguez.luis@helmac.ca' }
 s.platform = :ios, '13.0'
 s.source = { :git => 'file://#{__dir__}' }
 s.source_files = '**/*.{h,swift}'
end
