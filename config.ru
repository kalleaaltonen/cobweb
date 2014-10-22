
if Gem::Specification.find_all_by_name("sidekiq", ">=1.0.0").count > 1
  "Please remove Sidekiq"
end
