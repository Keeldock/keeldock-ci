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
#  6. No expression reads a whole context: no bare `secrets` or `vars` (so no toJSON(secrets),
#     format('{0}', vars), secrets[...] or secrets.*), and no toJSON(github), which carries the
#     job token. Only named members (secrets.NAME, vars.NAME) may be read.
#  7. Every create-github-app-token mint is one of the reviewed `with:` maps, key for key and
#     value for value: no extra permission-*, no other owner or repository, no other key.
#  8. Every drop-root call leaves keep-docker absent or sets it to the reviewed expression for
#     that file (an unconditional 'true' would keep Docker, which is root, for every concern).
#  9. A dispatcher's reviewed pre-flight job exists, does not continue on error, and every job
#     that calls a workflow, enters an environment or receives a secret needs it directly and
#     never runs past its failure (no always(), failure() or cancelled() in its `if`).
# 10. Reviewed input defaults (the vulnerability gate is `high`) and their pass-through from the
#     dispatcher to the concern and from the concern to the supply-chain composite.
require 'yaml'

root = ARGV[0] || '.'
failures = []

PROTECTED_JOBS = [['validation-concern.yml', 'validate']].freeze

E = '$' + '{{ '
MINTS = {
  '.github/workflows/validation-concern.yml' => [{
    'client-id' => "#{E}vars.SOURCE_READER_APP_ID }}",
    'private-key' => "#{E}secrets.SOURCE_READER_PRIVATE_KEY }}",
    'owner' => "#{E}env.SOURCE_REPOSITORY_OWNER }}",
    'repositories' => "#{E}env.SOURCE_REPOSITORY_NAME }}",
    'permission-contents' => 'read',
    'skip-token-revoke' => true
  }]
}.freeze
KEEP_DOCKER = {
  '.github/workflows/validation-concern.yml' => ["#{E}inputs.concern == 'db-containers' || inputs.concern == 'apphost-cold-start' }}", 'true']
}.freeze
PREFLIGHT = { '.github/workflows/validation.yml' => 'validate-input' }.freeze
INPUT_DEFAULTS = {
  '.github/workflows/validation.yml' => { 'vulnerability_gate' => 'high' },
  '.github/workflows/validation-concern.yml' => { 'vulnerability_gate' => 'high' }
}.freeze
# [job, step `uses:` (nil for the job's own `with:`), key, value]
PASS_THROUGH = {
  '.github/workflows/validation.yml' => [['validate', nil, 'vulnerability_gate', "#{E}inputs.vulnerability_gate }}"]],
  '.github/workflows/validation-concern.yml' => [['validate', './.github/actions/supply-chain', 'vulnerability-gate', "#{E}inputs.vulnerability_gate }}"]]
}.freeze
RUNS_PAST_FAILURE = /\b(always|failure|cancelled)\s*\(/

# Every expression in a parsed document: the inside of each `${{ }}`, and every `if:` value
# (which GitHub evaluates as an expression with or without the braces).
def expressions(node, key = nil, out = [])
  case node
  when Hash then node.each { |k, v| expressions(v, k.to_s, out) }
  when Array then node.each { |v| expressions(v, nil, out) }
  when String
    found = node.scan(/\$\{\{(.*?)\}\}/m).flatten
    found << node if key == 'if' && found.empty?
    out.concat(found)
  end
  out
end

def steps_of(doc, workflow)
  if workflow
    (doc['jobs'] || {}).flat_map { |_, job| job['steps'] || [] }
  else
    (doc['runs'] || {})['steps'] || []
  end
end

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

  # 6. no whole-context reads (string literals are removed before the scan)
  expressions(doc).each do |expr|
    code = expr.gsub(/'(?:[^']|'')*'/, "''")
    if code.match?(/(?<![.\w-])(secrets|vars)\b(?!\s*\.\s*[A-Za-z_])/) || code.match?(/\btoJSON\s*\(\s*github\s*\)/i)
      failures << "#{rel}: an expression reads a whole secrets, vars or github context: #{expr.strip[0, 60]}"
    end
  end

  # 7. reviewed token mints only
  mints = steps_of(doc, workflow).select { |st| st['uses'].to_s.start_with?('actions/create-github-app-token@') }
  failures << "#{rel}: the reviewed token mint is missing" if MINTS.key?(rel) && mints.empty?
  mints.each do |st|
    with = (st['with'] || {}).dup
    with['client-id'] = with.delete('app-id') if with.key?('app-id') && !with.key?('client-id')
    next if (MINTS[rel] || []).include?(with)
    failures << "#{rel}: token mint #{st['name'].inspect} is not a reviewed `with:` map (keys and values are an exact allow-list)"
  end

  # 8. keep-docker absent or the reviewed expression
  steps_of(doc, workflow).select { |st| st['uses'].to_s == './.github/actions/drop-root' }.each do |st|
    with = st['with'] || {}
    extra = with.keys - ['keep-docker']
    failures << "#{rel}: drop-root takes only keep-docker, not #{extra.join(', ')}" unless extra.empty?
    next unless with.key?('keep-docker')
    next if (KEEP_DOCKER[rel] || []).include?(with['keep-docker'])
    failures << "#{rel}: drop-root keep-docker must be absent or the reviewed expression, not #{with['keep-docker'].inspect}"
  end
  next unless workflow

  # 9. the dispatcher's pre-flight gates every protected job
  if (pre = PREFLIGHT[rel])
    jobs = doc['jobs'] || {}
    if !jobs.key?(pre)
      failures << "#{rel}: the reviewed pre-flight job #{pre} is missing"
    else
      failures << "#{rel}: the pre-flight job #{pre} must not continue on error" if jobs[pre].key?('continue-on-error')
      jobs.each do |job_id, job|
        next if job_id == pre || !(job['uses'] || job['environment'] || job['secrets'])
        failures << "#{rel}: job #{job_id} must need the pre-flight job #{pre} directly" unless Array(job['needs']).include?(pre)
        failures << "#{rel}: job #{job_id} may not run past a failed pre-flight (#{job['if']})" if job['if'].to_s.match?(RUNS_PAST_FAILURE)
      end
    end
  end

  # 10. reviewed input defaults and their pass-through
  triggers_doc = doc['on'] || doc[true] || {}
  (INPUT_DEFAULTS[rel] || {}).each do |input, want|
    got = %w[workflow_dispatch workflow_call].map { |t| triggers_doc.is_a?(Hash) && triggers_doc.dig(t, 'inputs', input, 'default') }.compact.first
    failures << "#{rel}: input #{input} must default to #{want.inspect}, not #{got.inspect}" unless got == want
  end
  (PASS_THROUGH[rel] || []).each do |job_id, uses, key, want|
    job = (doc['jobs'] || {})[job_id] || {}
    holders = uses ? (job['steps'] || []).select { |st| st['uses'].to_s == uses } : [job]
    if holders.empty? || holders.any? { |h| (h['with'] || {})[key] != want }
      failures << "#{rel}: job #{job_id}#{uses ? " step #{uses}" : ''} must pass #{key}: #{want}"
    end
  end

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
