# Contributing to Tymeslot

Thank you for your interest in contributing to Tymeslot! We welcome contributions from everyone, whether you're fixing bugs, adding features, improving documentation, or helping with testing.

## 📋 Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Support Tymeslot's Future](#support-tymeslots-future)
- [Types of Contributions](#types-of-contributions)
- [Helping Us Debug Issues](#helping-us-debug-issues)
- [Development Setup](#development-setup)
- [Code Standards](#code-standards)
- [Testing Guidelines](#testing-guidelines)
- [Contributor Licensing](#contributor-licensing)
- [Pull Request Process](#pull-request-process)
- [Issue Guidelines](#issue-guidelines)
- [Architecture Guidelines](#architecture-guidelines)
- [Tymeslot-Specific Guidelines](#tymeslot-specific-guidelines)
- [Getting Help](#getting-help)

## 📜 Code of Conduct

This project is governed by our [Code of Conduct](CODE_OF_CONDUCT.md). By participating, you agree to uphold it — please be respectful, inclusive, and professional in all interactions. Report unacceptable behaviour via [tymeslot.app/contact](https://tymeslot.app/contact).

## 💳 Support Tymeslot's Future

The best way to contribute to Tymeslot's sustainability is by **subscribing to our managed cloud service for just €9/month**. Your subscription directly funds development, ensures long-term maintenance, and helps sustain the open-source core that everyone benefits from.

👉 **[Try Tymeslot Cloud](https://tymeslot.app)** — 7-day free trial, no credit card required.

---

## 🤝 Types of Contributions

We welcome many types of contributions:

- 🐛 **Bug fixes** - Help us squash bugs and improve stability
- ✨ **New features** - Add functionality that benefits users
- 📚 **Documentation** - Improve guides, API docs, and examples
- 🧪 **Testing** - Add test coverage and improve test quality
- 🎨 **Themes** - Create new booking interface themes
- 🔌 **Integrations** - Add support for new calendar/video providers
- 🚀 **Performance** - Optimise code and improve efficiency
- 🔒 **Security** - Enhance security measures and practices

## 📦 Releases & Feedback

While we are constantly improving the codebase, we only publish official, stable releases through **GitHub Releases**. Not every commit to the repository is intended to be a production-ready release.

The most significant way you can contribute to Tymeslot is by providing **feedback**. Real-world usage reports, feature ideas, and constructive criticism are what truly help the project evolve. Even if you don't write a single line of code, sharing your experience is the biggest contribution you can make.

## 🚨 Helping Us Debug Issues

If you self-host Tymeslot, one of the most valuable things you can do is enable **admin alerts** and share the resulting reports with us when something breaks. Admin alerts are off by default — your data stays on your server unless you explicitly opt in.

### How to enable

Set two environment variables on your deployment:

```bash
ADMIN_ALERTS_ENABLED=true
ADMIN_ALERT_EMAIL=you@example.com
```

Both must be set. If `ADMIN_ALERT_EMAIL` is missing or invalid, no email is sent even when the flag is on.

When enabled, Tymeslot will email you a structured report whenever an alert is raised — failed webhooks, calendar sync errors, stuck Oban queues, broken integrations, and similar issues. Each report includes the alert category, severity, message, and a context table containing your Tymeslot version, deployment type, hostname, timestamp, and any relevant identifiers.

Identical alerts are deduplicated within a 24-hour window, so a persistent issue produces at most one email per day for the same content — you won't be spammed by a tight error loop.

### Sharing reports with the project

These reports are designed to be copy-paste friendly. If you encounter an issue you'd like us to investigate, open a GitHub issue at <https://github.com/Tymeslot/tymeslot/issues> and paste the relevant alert. **Please redact any sensitive values** (user IDs, email addresses, charge IDs, internal hostnames) before sharing publicly — we only need the technical details to reproduce the failure.

If the alert references logs, attach the relevant log lines as well. The more context you include, the faster we can diagnose and fix the issue.

## 🛠️ Development Setup

### Prerequisites

- **Elixir**: ~> 1.20 (with Erlang 28.3.3+)
- **Node.js**: 18+ (for asset compilation)
- **PostgreSQL**: 14+
- **Git**: Latest version

### Local Development

1. **Fork and clone the repository**
   ```bash
   git clone https://github.com/your-username/tymeslot.git
   cd tymeslot
   ```

2. **Install all dependencies**
   ```bash
   mix setup
   ```

3. **Start the development server**
   ```bash
   mix phx.server
   ```

### Optional: OAuth Provider Setup

For testing authentication and calendar integrations:

- **Google OAuth**: [Google Cloud Console](https://console.cloud.google.com/)
- **GitHub OAuth**: [GitHub Developer Settings](https://github.com/settings/developers)
- **Microsoft OAuth**: [Azure App Registration](https://portal.azure.com/)

Configure OAuth credentials in your environment for full functionality testing.

For detailed setup instructions including required redirect URIs and API permissions, see:
- [Docker OAuth Setup Guide](README-Docker.md#oauth-provider-setup)
- [Cloudron OAuth Setup Guide](README-Cloudron.md#oauth-provider-setup)

## 📏 Code Standards

### Elixir Conventions

- Follow the [Elixir Style Guide](https://github.com/christopheradams/elixir_style_guide)
- Use meaningful variable and function names
- Write clear, concise documentation
- Prefer pattern matching over conditional logic
- Keep functions small and focused

### Code Formatting

```bash
# Format all code
mix format

# Check formatting
mix format --check-formatted
```

### Code Quality

```bash
# Run Credo for code analysis
mix credo --strict

# Run Dialyzer for type checking
mix dialyzer
```

### Module Organisation

Tymeslot follows a **domain- and feature-driven module structure**. Modules are grouped by what they do for the business, not by technical role. Each domain owns its own schemas, queries, and logic — colocated under one namespace.

```
lib/tymeslot/
├── auth/                     # Authentication domain
│   ├── auth.ex               # Public context API
│   ├── user_schema.ex        # Ecto schema
│   └── user_queries.ex       # Database queries
├── availability/             # Availability calculation domain
├── bookings/                 # Meeting booking domain
├── integrations/             # External service integrations
├── jobs/                     # Oban job definitions
├── meetings/                 # Meeting management domain
├── notifications/            # Email and notification system
├── security/                 # Security and validation
└── workers/                  # Oban background workers
```

### Key Patterns to Follow

1. **Module Aliases**: Always at the top of files, alphabetically ordered
   ```elixir
   defmodule MyModule do
     alias Tymeslot.Auth
     alias Tymeslot.Profiles
     alias TymeslotWeb.CoreComponents
   end
   ```

2. **LiveView Components**: Single root HTML element
   ```elixir
   def render(assigns) do
     ~H"""
     <div class="my-component">
       <%!-- All content wrapped in single element --%>
     </div>
     """
   end
   ```

3. **Repository Pattern**: Use dedicated query modules, colocated with their domain
   ```elixir
   # Good — query module owns all Repo calls
   Tymeslot.Auth.UserQueries.find_by_email(email)

   # Avoid — bypasses the query module boundary
   Repo.get_by(User, email: email)
   ```

4. **Repo calls belong in query modules**: `Repo.get`, `Repo.insert`, `Repo.update`, `Repo.delete`, `Repo.all`, `Repo.one`, `Repo.exists?`, and similar must live in `*_queries.ex` files. Only `Repo.transaction`, `Repo.rollback`, and `Repo.preload` are permitted in domain context modules.

5. **HEEx comments only**: Use `<%!-- --%>` in `.heex` files and `~H` sigils. Never use HTML comments (`<!-- -->`); they are sent to the browser.

## 🧪 Testing Guidelines

### Running Tests

```bash
# Run all tests
mix test

# Run with coverage
mix test --cover

# Run specific test file
mix test test/tymeslot/auth/auth_test.exs

# Run a single test by line number
mix test test/tymeslot/auth/auth_test.exs:42

# Run Elixir tests only (skip JS)
mix test.elixir
```

### Test Coverage

- **Required**: All new public context functions, LiveView events, Oban workers, and controller actions must include tests.
- **Behaviour over implementation**: Assert on return values, database state, and rendered HTML — not internal function calls or private module details.

### Writing Tests

Every test module must declare at least one `@moduletag` from the approved taxonomy defined in `test/support/tag_taxonomy.ex`.

**Domain tags**: `:auth`, `:availability`, `:bookings`, `:calendar`, `:database`, `:emails`, `:integrations`, `:meetings`, `:meeting_types`, `:notifications`, `:payments`, `:profiles`, `:scheduling`, `:security`, `:themes`, `:workers`, and more.

**Web layer tags**: `:components`, `:controllers`, `:live`, `:plugs`, `:hooks`

**Test type tags**: `:unit`, `:integration`, `:schema`, `:queries`, `:migrations`

Example test structure:
```elixir
defmodule Tymeslot.Auth.AuthenticationTest do
  use Tymeslot.DataCase

  @moduletag :auth
  @moduletag :unit

  alias Tymeslot.Auth.Authentication

  describe "authenticate_user/2" do
    test "returns user for valid credentials" do
      user = Factory.insert(:user)

      assert {:ok, authenticated_user} =
        Authentication.authenticate_user(user.email, "valid_password")
      assert authenticated_user.id == user.id
    end

    test "returns error for invalid credentials" do
      assert {:error, :invalid_credentials} =
        Authentication.authenticate_user("invalid@email.com", "wrong_password")
    end
  end
end
```

### Test Organisation

- `test/tymeslot/` - Unit tests for business logic
- `test/tymeslot_web/` - Tests for web layer (controllers, live views)
- `test/support/` - Test helpers and factories

### Test Philosophy

- **Test behaviour, not implementation.** Assert on outcomes visible to callers.
- **One concept per test.** Each test should have a single, clear reason to fail.
- **No `Process.sleep/1`.** Use `assert_receive`, ExUnit async helpers, or Oban's test mode.
- **Mock at system boundaries only.** Mock external HTTP calls and third-party APIs — not your own modules.

## 📝 Contributor Licensing

Tymeslot Core is distributed under the [GNU Affero General Public License v3.0 or later](LICENSE). Contributing involves two separate steps, and they certify different things:

| | What it certifies | How often |
|---|---|---|
| [DCO sign-off](#signing-off-your-commits) | **Provenance.** You wrote the code, or otherwise have the right to submit it. | Every commit |
| [Contributor Licence Agreement](CLA.md) | **Rights.** You grant Diletta Luna OÜ a licence broad enough to keep distributing and relicensing the project as a whole. | Once, ever |

Both are required, and neither substitutes for the other. The sign-off has a fixed public meaning, set by the [DCO](DCO) text, and that text says nothing about licensing rights; the CLA covers what the DCO deliberately leaves out. You keep the copyright in your work either way.

Read [CLA.md](CLA.md) before opening a pull request. If you cannot agree to it, please do not submit a contribution.

### Signing the CLA

Open your pull request as normal. A bot will comment asking you to sign, and you sign by replying on the pull request with exactly:

```
I have read the Tymeslot Contributor Licence Agreement and I hereby sign it
```

You sign once. The record covers your later contributions too, and lives on the `cla-signatures` branch of this repository.

If you are contributing as part of your job, read [Contributing on behalf of an employer](CLA.md#contributing-on-behalf-of-an-employer) first: your employer may hold the rights, in which case your personal signature is not the one we need.

### Signing off your commits

Tymeslot uses the [Developer Certificate of Origin](DCO) (DCO). **Every commit in a contribution must be signed off.** The sign-off is how you certify, on the public record and per commit, that you wrote the code or otherwise have the right to submit it.

Add the sign-off automatically with the `-s` flag:

```bash
git commit -s -m "feat(auth): add GitHub OAuth integration"
```

This appends a line to your commit message using your configured Git name and email:

```
Signed-off-by: Your Name <you@example.com>
```

Use your real name and an email you can be reached at. Pull requests are only merged once **all** their commits are signed off and the CLA is signed. To add the sign-off to commits you have already made, run `git rebase --signoff <base>` (or `git commit --amend -s` for the most recent commit) and force-push the branch.

## 🔄 Pull Request Process

### Branch Naming

Use descriptive branch names:
- `feature/add-teams-video-integration`
- `fix/calendar-sync-timezone-bug`
- `docs/improve-oauth-setup-guide`
- `refactor/simplify-availability-calculation`

### Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/) format:
```
feat(auth): add GitHub OAuth integration
fix(calendar): resolve timezone conversion bug
docs(readme): update installation instructions
test(bookings): add integration tests for meeting creation
refactor(themes): extract common theme utilities
```

Sign off every commit with the `-s` flag (`git commit -s`); see [Signing off your commits](#signing-off-your-commits).

The changelog is auto-generated from `feat` and `fix` commits. To exclude a `feat` or `fix` commit from the changelog (e.g. internal test fixes, Dialyzer suppressions), add a `Changelog: skip` footer:

```
fix(core): unwrap tuple in OAuth session test

Changelog: skip
```

### Definition of Done

A task is complete only when all of the following pass:

```bash
mix test          # 0 failures
mix credo --strict  # all issues resolved
mix dialyzer      # no warnings
mix format --check-formatted  # properly formatted
```

### Pull Request Checklist

Before submitting a PR, ensure:

- [ ] Code follows style guidelines (`mix format`, `mix credo --strict`)
- [ ] Tests pass (`mix test`)
- [ ] New functionality includes tests with appropriate `@moduletag` declarations
- [ ] Documentation is updated if needed
- [ ] Security considerations are addressed
- [ ] Breaking changes are clearly documented
- [ ] PR description explains the change and motivation
- [ ] All commits are signed off (`git commit -s`), certifying the [DCO](DCO)
- [ ] The [Contributor Licence Agreement](CLA.md) is signed (the bot will prompt you on the PR)

### PR Description Template

```markdown
## Description
Brief description of changes and motivation.

## Type of Change
- [ ] Bug fix
- [ ] New feature
- [ ] Documentation update
- [ ] Performance improvement
- [ ] Refactoring

## Testing
- [ ] Unit tests added/updated
- [ ] Integration tests added/updated
- [ ] Manual testing completed

## Security Considerations
Any security implications of this change.

## Breaking Changes
List any breaking changes and migration steps.
```

## 🐛 Issue Guidelines

### Bug Reports

When reporting bugs, include:

1. **Clear title** describing the issue
2. **Steps to reproduce** the problem
3. **Expected behaviour** vs **actual behaviour**
4. **Environment details** (OS, Elixir version, browser)
5. **Error logs** or screenshots if applicable
6. **Minimal reproduction case** if possible

### Feature Requests

For new features, provide:

1. **Problem statement** - What need does this address?
2. **Proposed solution** - How should it work?
3. **Alternatives considered** - Other approaches evaluated
4. **Additional context** - Screenshots, mockups, examples

### Issue Labels

We use these labels to organise issues:

- `bug` - Something isn't working
- `enhancement` - New feature or improvement
- `documentation` - Documentation improvements
- `good first issue` - Good for newcomers
- `help wanted` - Community contributions welcome
- `security` - Security-related issues
- `performance` - Performance improvements

## 🏗️ Architecture Guidelines

### Project Structure

This repository contains **Core**: the complete, self-contained scheduling product and the open-source codebase for self-hosters. It owns all domain logic, database schemas, migrations, the HTTP endpoint, and the full web UI, under the `Tymeslot.*` and `TymeslotWeb.*` namespaces. Development happens natively here on GitHub — issues, pull requests, and releases all live in this repository.

The managed cloud offering (tymeslot.app) is built in a separate, private repository as a thin overlay that depends on this one. It adds marketing pages, billing, legal agreements, and subscription management. That split shapes a few rules for code in this repository:

### Core/SaaS Boundary

- **Core never references SaaS.** No imports, calls, or checks for SaaS presence anywhere in this codebase. Core behaves identically whether or not the SaaS overlay is deployed on top of it.
- **Feature flags bridge behavioural differences.** When the managed offering needs Core to behave differently, define a config flag here with a safe default (for example `config :tymeslot, :enforce_legal_agreements, false`); the overlay overrides it in its own config.

### Domain-Driven Design

1. **Bounded Contexts**: Each domain (auth, bookings, etc.) is isolated with a single public context module as its API.
2. **Domain Logic**: Business rules live in domain modules, not controllers or LiveViews.
3. **Repository Pattern**: All database access through dedicated `*_queries.ex` modules.
4. **No queries in `mount/3`**: Defer data loading to `handle_params/3` to avoid double-loading.

### Security First

Always consider security when contributing:

1. **Input Validation**: Use security input processors
2. **Rate Limiting**: Apply appropriate rate limits via `Tymeslot.Security.RateLimiter`
3. **Encryption**: Encrypt sensitive data (API keys, tokens)
4. **Sanitisation**: Sanitise all user inputs
5. **Authorisation**: Verify user permissions

### Performance Considerations

1. **Database Queries**: Use efficient queries and indexes
2. **External APIs**: Implement circuit breakers and timeouts
3. **Caching**: Cache expensive operations appropriately
4. **Background Jobs**: Use Oban for async processing — never raw `spawn/1` or `Task.async/1`

## 🎯 Tymeslot-Specific Guidelines

### Theme Development

When creating new themes:

1. **Theme Structure**: Follow the theme behaviour pattern
2. **Component Isolation**: Themes are self-contained — do not reference `app.css` or Tailwind utilities
3. **Consistent Functionality**: All themes must support the same scheduling features
4. **Mobile Responsive**: Ensure mobile compatibility

Example theme structure:
```
lib/tymeslot_web/themes/
└── my_theme/
    ├── theme.ex                 # Theme behaviour implementation
    ├── scheduling/              # Scheduling flow pages
    │   ├── live.ex
    │   ├── wrapper.ex
    │   └── components/          # Theme-specific components
    └── meeting/                 # Meeting management pages
        ├── cancel.ex
        └── reschedule.ex
```

### Integration Providers

When adding new calendar/video providers:

1. **Provider Pattern**: Implement the provider behaviour
2. **OAuth Flow**: Handle authentication properly
3. **Error Handling**: Implement robust error handling
4. **Rate Limiting**: Respect provider rate limits
5. **Circuit Breakers**: Use circuit breakers for resilience
6. **HTTP Client**: Use `Req` — never `:httpoison`, `:tesla`, or `:httpc`

### Email Templates

For email template changes:

1. **MJML**: Use MJML for responsive templates
2. **Multi-format**: Support HTML and plain text
3. **Attachments**: Include calendar files (.ics) where appropriate
4. **Testing**: Test across email clients
5. **Localisation**: Consider internationalisation

### Database Migrations

1. **Generate migrations** with `mix ecto.gen.migration <name>` — never create migration files manually.
2. **Backfill before constraining**: When adding constraints to existing tables, handle violating rows in the same migration.
3. **Use `IF NOT EXISTS` / `IF EXISTS`** in repair migrations for idempotency.

### Security Contributions

Security-related contributions should:

1. **Follow Security Policy**: Report vulnerabilities privately first
2. **Input Processors**: Use existing security input processors
3. **Validation**: Add comprehensive validation
4. **Logging**: Add appropriate security logging
5. **Testing**: Include security test cases

## 🆘 Getting Help

### Documentation

- [README.md](README.md) - Project overview and setup
- [DESIGN_LANGUAGE.md](DESIGN_LANGUAGE.md) - UI/UX guidelines
- [docs/THEME_DEVELOPMENT_GUIDE.md](docs/THEME_DEVELOPMENT_GUIDE.md) - Theme creation
- [DEBUG_ROUTES.md](DEBUG_ROUTES.md) - Debug utilities

### Communication

- **Issues**: Use GitHub issues for bug reports and feature requests
- **Discussions**: Use GitHub Discussions for questions and ideas
- **Security**: Never use a public issue — follow the [Security Policy](SECURITY.md) to report vulnerabilities privately

### Development Resources

- **Elixir**: [Official Guide](https://elixir-lang.org/getting-started/introduction.html)
- **Phoenix**: [Phoenix Guides](https://hexdocs.pm/phoenix/overview.html)
- **LiveView**: [LiveView Guide](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html)
- **Ecto**: [Ecto Guide](https://hexdocs.pm/ecto/Ecto.html)

## 🙏 Recognition

Contributors will be recognised in:

- **README.md** - Major contributors
- **Release Notes** - Feature contributors
- **Documentation** - Documentation contributors

Thank you for contributing to Tymeslot! Your efforts help make scheduling better for everyone. 🚀

---

**Questions?** Don't hesitate to ask in the issues or reach out to the maintainers.
