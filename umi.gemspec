# frozen_string_literal: true

require_relative "lib/umi/version"

Gem::Specification.new do |spec|
  spec.name = "umi"
  spec.version = Umi::VERSION
  spec.authors = ["Joseph Wecker"]
  spec.email = ["joseph@wecker.io"]

  spec.summary = "OTP-style resilience patterns for Ruby 4.0"
  spec.description = <<~DESC
    Umi (海, "sea/deep water") brings OTP-like resilience patterns to Ruby 4.0.
    It solves cascading failures, blocked threads, and crack propagation using
    Ruby-native idioms built on Ractor isolation.
  DESC
  spec.homepage = "https://github.com/josephwecker/umi"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata['rubygems_mfa_required'] = 'true'

  # Only include lib files in the gem
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").select do |f|
      f.start_with?("lib/")
    end
  end
  spec.require_paths = ["lib"]
end
