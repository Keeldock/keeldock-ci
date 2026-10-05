# Rules every workflow and composite in the repository must satisfy, whatever its trust tier.
# Usage: ruby check-universal.rb [root]   (root defaults to the current directory)
#
#  1. Every non-local `uses:` is pinned to a full 40-character commit SHA (no tag, branch or
#     docker:// reference).
#  2. Every workflow declares `permissions: {}` at the top level, so each job must ask for
#     exactly what it needs.
#  3. No workflow uses the `pull_request_target` trigger.
#  4. No workflow passes `secrets: inherit`.
#  5. Only the reviewed protected job enters the source-read environment: the `validate` job
#     of validation-concern.yml, whose inline mint, checkout and revoke check-concern.sh pins.
#     Any other job that names any environment fails (an environment is where secrets live).
require 'yaml'

root = ARGV[0] || '.'
failures = []

PROTECTED_JOBS = [['validation-concern.yml', 'validate']].freeze

PIN = /\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(\/[A-Za-z0-9_.\/-]+)?@[0-9a-f]{40}\z/
files = Dir.glob(File.join(root, '.github/workflows/*.yml')) + Dir.glob(File.join(root, '.github/actions/*/action.yml'))
files.sort.each do |file|
  rel = file.sub(%r{\A#{Regexp.escape(root)}/?}, '')
  text = File.read(file, encoding: 'UTF-8')
  doc = YAML.safe_load(text, aliases: false) || {}
  workflow = rel.start_with?('.github/workflows/')

  # 1. pinned uses (workflow steps and job-level reusable calls, and composite steps)
  uses = []
  if workflow
    (doc['jobs'] || {}).each_value do |job|
      uses << job['uses'] if job['uses']
      (job['steps'] || []).each { |st| uses << st['uses'] if st['uses'] }
    end
  else
    ((doc['runs'] || {})['steps'] || []).each { |st| uses << st['uses'] if st['uses'] }
  end
  uses.each do |ref|
    next if ref.start_with?('./')
    failures << "#{rel}: `uses: #{ref}` is not pinned to a full 40-character commit SHA" unless ref.match?(PIN)
  end
  next unless workflow

  # 2. permissions: {} at the top level
  failures << "#{rel}: no top-level `permissions: {}`" unless doc['permissions'] == {}

  # 3. pull_request_target (parsed trigger keys; a flow-style `on: [..]` list is parsed too)
  triggers = doc['on'] || doc[true] || {}
  keys = triggers.is_a?(Hash) ? triggers.keys.map(&:to_s) : Array(triggers).map(&:to_s)
  failures << "#{rel}: uses the pull_request_target trigger" if keys.include?('pull_request_target')

  # 4. secrets: inherit
  (doc['jobs'] || {}).each do |job_id, job|
    failures << "#{rel}: job #{job_id} passes `secrets: inherit`" if job['secrets'] == 'inherit'
  end

  # 5. only the reviewed protected job enters source-read
  (doc['jobs'] || {}).each do |job_id, job|
    env = job['environment']
    env_name = (env.is_a?(Hash) ? env['name'] : env).to_s
    next if env_name.empty? || PROTECTED_JOBS.include?([File.basename(rel), job_id])
    failures << "#{rel}: job #{job_id} enters an environment (#{env_name}); only validation-concern.yml validate may"
  end
end

unless failures.empty?
  warn failures.join("\n")
  exit 1
end
puts "universal rules: #{files.length} files checked"
