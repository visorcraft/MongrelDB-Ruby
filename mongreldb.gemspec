# frozen_string_literal: true

require_relative "lib/mongreldb/version"

Gem::Specification.new do |spec|
  spec.name          = "mongreldb"
  spec.version       = MongrelDB::VERSION
  spec.summary       = "Pure Ruby HTTP client for MongrelDB"
  spec.description   = "Pure Ruby application-facing client for MongrelDB - a " \
                       "fast embedded+server database with SQL, vector search, " \
                       "full-text search, and AI-native retrieval. Built on the " \
                       "standard-library net/http; no external gems required at " \
                       "runtime. The API mirrors the MongrelDB PHP/Go/Java clients."
  spec.authors       = ["Visorcraft"]
  spec.email         = ["support@visorcraft.com"]
  spec.homepage      = "https://github.com/visorcraft/MongrelDB-Ruby"
  spec.license       = "MIT OR Apache-2.0"
  spec.required_ruby_version = ">= 3.0.0"

  # No runtime dependencies - standard library only (net/http, json, uri, ...).
  spec.metadata = {
    "homepage_uri"          => "https://github.com/visorcraft/MongrelDB-Ruby",
    "source_code_uri"       => "https://github.com/visorcraft/MongrelDB-Ruby",
    "bug_tracker_uri"       => "https://github.com/visorcraft/MongrelDB-Ruby/issues",
    "changelog_uri"         => "https://github.com/visorcraft/MongrelDB-Ruby/releases",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir.glob("lib/**/*.rb") + %w[README.md LICENSE-APACHE LICENSE-MIT CONTRIBUTING.md SECURITY.md]
  spec.require_paths = ["lib"]
end
