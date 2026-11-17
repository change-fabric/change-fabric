# Fixture agents guide

overnight.agent_tags_allowed: yes
overnight.flags_adapter: FLAGS_TOKEN=fixture-not-a-secret bin/flags
overnight.staging_workflow: deploy-staging.yml
overnight.production_workflow: deploy-production.yml
overnight.version_endpoint: https://app.example.test/version
overnight.migration_command: bin/migrate
overnight.terraform_wrapper: bin/tf
