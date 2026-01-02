# Contributing to Tymeslot

Thank you for your interest in contributing to Tymeslot! We welcome contributions from everyone, whether you're fixing bugs, adding features, improving documentation, or helping with testing.

## 📋 Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Types of Contributions](#types-of-contributions)
- [Development Setup](#development-setup)
- [Code Standards](#code-standards)
- [Testing Guidelines](#testing-guidelines)
- [Pull Request Process](#pull-request-process)
- [Issue Guidelines](#issue-guidelines)
- [Architecture Guidelines](#architecture-guidelines)
- [Tymeslot-Specific Guidelines](#tymeslot-specific-guidelines)
- [Getting Help](#getting-help)

## 📜 Code of Conduct

By participating in this project, you agree to abide by our Code of Conduct. Please be respectful, inclusive, and professional in all interactions.

## 🤝 Types of Contributions

We welcome many types of contributions:

- 🐛 **Bug fixes** - Help us squash bugs and improve stability
- ✨ **New features** - Add functionality that benefits users
- 📚 **Documentation** - Improve guides, API docs, and examples
- 🧪 **Testing** - Add test coverage and improve test quality
- 🎨 **Themes** - Create new booking interface themes
- 🔌 **Integrations** - Add support for new calendar/video providers
- 🚀 **Performance** - Optimize code and improve efficiency
- 🔒 **Security** - Enhance security measures and practices

## 🛠️ Development Setup

### Prerequisites

- **Elixir**: 1.19.3+ (with Erlang 28.1.1+)
- **Node.js**: 18+ (for asset compilation)
- **PostgreSQL**: 14+
- **Git**: Latest version

### Local Development

1. **Fork and clone the repository**
   ```bash
   git clone https://github.com/your-username/tymeslot.git
   cd tymeslot
   ```

2. **Install Elixir dependencies**
   ```bash
   mix deps.get
   ```

3. **Install Node.js dependencies**
   ```bash
   cd assets && npm install && cd ..
   ```

4. **Set up environment variables**
   ```bash
   cp .env.example .env
   # Edit .env with your local configuration
   ```

5. **Create and migrate database**
   ```bash
   mix ecto.create
   mix ecto.migrate
   ```

6. **Start the development server**
   ```bash
   mix phx.server
   ```

### Optional: OAuth Provider Setup

For testing authentication and calendar integrations:

- **Google OAuth**: [Google Cloud Console](https://console.cloud.google.com/)
- **GitHub OAuth**: [GitHub Developer Settings](https://github.com/settings/developers)
- **Microsoft OAuth**: [Azure App Registration](https://portal.azure.com/)

Add OAuth credentials to your `.env` file for full functionality testing.

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
mix credo

# Run Dialyzer for type checking
mix dialyzer
```

### Module Organization

Follow our domain-driven structure:

```
lib/tymeslot/
├── auth/                     # Authentication domain
├── availability/             # Availability calculation domain
├── bookings/                # Meeting booking domain
├── integrations/            # External service integrations
├── notifications/           # Email and notification system
├── security/               # Security and validation
├── database_schemas/       # Ecto schemas
└── database_queries/       # Query modules
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
       <!-- All content wrapped in single element -->
     </div>
     """
   end
   ```

3. **Repository Pattern**: Use dedicated query modules
   ```elixir
   # Good
   UserQueries.find_by_email(email)
   
   # Avoid
   Repo.get_by(User, email: email)
   ```

## 🧪 Testing Guidelines

### Running Tests

```bash
# Run all tests
mix test

# Run with coverage
mix test --cover

# Run specific test file
mix test test/tymeslot/auth/auth_test.exs

# Run tests matching a pattern
mix test --grep "user registration"
```

### Test Coverage

- **Target**: 75% overall coverage
- **Current**: 11.17% (help us improve!)
- **Required**: All new features must include tests
- **Integration tests**: Include OAuth setup tags

### Writing Tests

1. **Unit Tests**: Test individual functions and modules
2. **Integration Tests**: Test complete user workflows
3. **LiveView Tests**: Test real-time interactions
4. **Security Tests**: Test validation and sanitization

Example test structure:
```elixir
defmodule Tymeslot.Auth.AuthenticationTest do
  use Tymeslot.DataCase
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

### Test Organization

- `test/tymeslot/` - Unit tests for business logic
- `test/tymeslot_web/` - Tests for web layer (controllers, live views)
- `test/integration/` - End-to-end integration tests
- `test/support/` - Test helpers and factories

## 🔄 Pull Request Process

### Branch Naming

Use descriptive branch names:
- `feature/add-teams-video-integration`
- `fix/calendar-sync-timezone-bug`
- `docs/improve-oauth-setup-guide`
- `refactor/simplify-availability-calculation`

### Commit Messages

Follow conventional commit format:
```
type(scope): description

feat(auth): add GitHub OAuth integration
fix(calendar): resolve timezone conversion bug
docs(readme): update installation instructions
test(bookings): add integration tests for meeting creation
refactor(themes): extract common theme utilities
```

### Pull Request Checklist

Before submitting a PR, ensure:

- [ ] Code follows style guidelines (`mix format`, `mix credo`)
- [ ] Tests pass (`mix test`)
- [ ] New functionality includes tests
- [ ] Documentation is updated if needed
- [ ] Security considerations are addressed
- [ ] Breaking changes are clearly documented
- [ ] PR description explains the change and motivation

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
3. **Expected behavior** vs **actual behavior**
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

We use these labels to organize issues:

- `bug` - Something isn't working
- `enhancement` - New feature or improvement
- `documentation` - Documentation improvements
- `good first issue` - Good for newcomers
- `help wanted` - Community contributions welcome
- `security` - Security-related issues
- `performance` - Performance improvements

## 🏗️ Architecture Guidelines

### Domain-Driven Design

Tymeslot follows domain-driven design principles:

1. **Bounded Contexts**: Each domain (auth, bookings, etc.) is isolated
2. **Domain Logic**: Business rules live in domain modules, not controllers
3. **Repository Pattern**: Data access through dedicated query modules
4. **Event-Driven**: Use events for cross-domain communication

### Security First

Always consider security when contributing:

1. **Input Validation**: Use security input processors
2. **Rate Limiting**: Apply appropriate rate limits
3. **Encryption**: Encrypt sensitive data (API keys, tokens)
4. **Sanitization**: Sanitize all user inputs
5. **Authorization**: Verify user permissions

### Performance Considerations

1. **Database Queries**: Use efficient queries and indexes
2. **External APIs**: Implement circuit breakers and timeouts
3. **Caching**: Cache expensive operations appropriately
4. **Background Jobs**: Use Oban for async processing

## 🎯 Tymeslot-Specific Guidelines

### Theme Development

When creating new themes:

1. **Theme Structure**: Follow the theme behavior pattern
2. **Component Isolation**: Themes should be self-contained
3. **Consistent Functionality**: All themes must support the same features
4. **CSS Organization**: Use the modular CSS structure
5. **Mobile Responsive**: Ensure mobile compatibility

Example theme structure:
```
lib/tymeslot_web/themes/
└── my_theme/
    ├── my_theme.ex              # Theme behavior implementation
    ├── components/              # Theme-specific components
    ├── assets/                  # Theme CSS/JS
    └── templates/               # Theme templates
```

### Integration Providers

When adding new calendar/video providers:

1. **Provider Pattern**: Implement the provider behavior
2. **OAuth Flow**: Handle authentication properly
3. **Error Handling**: Implement robust error handling
4. **Rate Limiting**: Respect provider rate limits
5. **Circuit Breakers**: Use circuit breakers for resilience

### Email Templates

For email template changes:

1. **MJML**: Use MJML for responsive templates
2. **Multi-format**: Support HTML and plain text
3. **Attachments**: Include calendar files (.ics)
4. **Testing**: Test across email clients
5. **Localization**: Consider internationalization

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
- **Email**: security@tymeslot.app for security-related issues

### Development Resources

- **Elixir**: [Official Guide](https://elixir-lang.org/getting-started/introduction.html)
- **Phoenix**: [Phoenix Guides](https://hexdocs.pm/phoenix/overview.html)
- **LiveView**: [LiveView Guide](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html)
- **Ecto**: [Ecto Guide](https://hexdocs.pm/ecto/Ecto.html)

## 🙏 Recognition

Contributors will be recognized in:

- **README.md** - Major contributors
- **Release Notes** - Feature contributors
- **Documentation** - Documentation contributors

Thank you for contributing to Tymeslot! Your efforts help make scheduling better for everyone. 🚀

---

**Questions?** Don't hesitate to ask in the issues or reach out to the maintainers.
