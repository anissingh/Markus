require_relative 'boot'

require 'rails/all'

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

# Settings in config/environments/* take precedence over those specified here.
# Application configuration can go into files in config/initializers
# -- all .rb files in that directory are automatically loaded after loading
# the framework and any gems in your application.
module Markus
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version
    config.load_defaults 5.2
    # Configure sensitive parameters which will be filtered from the log file
    config.filter_parameters += [:password]
    # Set the timezone
    config.time_zone = 'Eastern Time (US & Canada)'
    # Add all config/locales subdirs
    config.i18n.load_path += Dir[Rails.root.join('config', 'locales', '**', '*.{rb,yml}')]
    # Use Resque for background jobs
    config.active_job.queue_adapter = :resque
    # Use RSpec as test framework
    config.generators do |g|
      g.test_framework :rspec
    end

    #TODO review initializers
    #TODO precompiled assets
    #TODO database pool connections and unicorn workers
    # Enable the asset pipeline
    config.assets.enabled = true
    config.assets.version = '1.0'
    config.assets.quiet = true
  end
end
