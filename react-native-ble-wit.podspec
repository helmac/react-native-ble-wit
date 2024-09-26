require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  s.name		= "react-native-ble-wit"
  s.summary		= "A WIT BLE module for react native."
  s.version		= package['version']
  s.authors		= { "helmac" => "https://github.com/helmac" }
  s.homepage    	= "https://github.com/helmac/react-native-ble-wit"
  s.license     	= "Apache-2.0"
  s.platform    	= :ios, "13.0"
  s.source      	= { :git => "https://github.com/helmac/react-native-ble-wit.git" }
  s.source_files = "ios/**/*.{h,c,cc,cpp,m,mm,swift}"

  s.dependency 'React-Core'
  s.dependency 'WitSDK'
end
