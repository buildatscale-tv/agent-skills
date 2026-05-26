You are working on GitHub issue #{{ISSUE}}: {{TITLE}}

{{BODY}}

Source: {{URL}}

Setup already done for you:
  - Branch `{{AGENT_BRANCH}}` is checked out in the workspace
  - Dependencies are installed
  - The dev server is running on port {{APP_PORT_INTERNAL}} with hot
    reload enabled, so the reviewer will see your changes live in
    their browser as you save files

Notes:
  - {{LOCKFILE_GUIDANCE}}

Implement the change end-to-end, then:

  1. commit with a clear subject line
  2. git push -u origin {{AGENT_BRANCH}}
  3. gh pr create --head {{AGENT_BRANCH}} --title "<your commit subject>" --body "Closes {{URL}}"

Do not stop until the PR is open.
