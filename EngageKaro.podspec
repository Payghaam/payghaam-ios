Pod::Spec.new do |s|
  s.name             = 'EngageKaro'
  s.version          = '0.1.0'
  s.summary          = 'EngageKaro iOS SDK — direct APNs push, identify, tags, events.'
  s.description      = 'Native Swift SDK. Also distributed via Swift Package Manager ' \
                        '(see Package.swift) for apps that integrate it directly; this ' \
                        'podspec exists so CocoaPods-based wrapper SDKs (Flutter, React ' \
                        'Native) can depend on the same implementation instead of ' \
                        'duplicating it — see sdk-native-wrapper-design.md.'
  s.homepage         = 'https://github.com/msamoeed/engagekaro'
  s.license          = { :type => 'MIT' }
  s.author           = { 'EngageKaro' => 'dev@engagekaro.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Sources/EngageKaro/**/*.swift'
  s.ios.deployment_target = '15.0'
  s.swift_version    = '5.9'
end
