# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# Dev-only: minitest ships with the Ruby standard library, but pin it for a
# stable, reproducible CI run. Not required at runtime.
group :development, :test do
  gem "minitest", "~> 5.22"
  gem "rake", "~> 13.0"
end
