# Composite-action structure check (see check_composite_action in lib.sh).
# Usage: ruby composite-action.rb <action.yml>
#
# This repository has no source-checkout composite: the private checkout, the identity check and
# the token revoke are inline in validation-concern.yml, where check-concern.sh pins them. So no
# composite may mint a token, check out a repository other than this one, or name the private
# source.
require 'yaml'
file = ARGV[0]
doc = YAML.safe_load(File.read(file), aliases: false)
failures = []
runs = doc['runs'] || {}
failures << "#{file}: runs.using must be composite" unless runs['using'] == 'composite'
(runs['steps'] || []).each_with_index do |st, i|
  label = st['name'] || "step #{i + 1}"
  if st['uses'].to_s.start_with?('actions/create-github-app-token@')
    failures << "#{file}: #{label.inspect} mints a token; only validation-concern.yml may"
  end
  if st['uses'].to_s.start_with?('actions/checkout@') && st.dig('with', 'repository')
    failures << "#{file}: #{label.inspect} checks out another repository; only validation-concern.yml may"
  end
  if st['run']
    failures << "#{file}: #{label.inspect} has no shell" unless st['shell']
    failures << "#{file}: #{label.inspect} interpolates an expression inside run (use env:)" if st['run'].include?('$' + '{{')
    failures << "#{file}: #{label.inspect} calls the token endpoint" if st['run'].include?('installation/token')
  end
end
unless failures.empty?
  warn failures.join("\n")
  exit 1
end
