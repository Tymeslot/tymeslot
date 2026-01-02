# Integration Tests

This directory contains integration tests for OAuth authentication providers (Google and GitHub) and calendar integrations. These tests are designed to validate that your OAuth setup and calendar integrations are correctly configured by making real API calls to the respective providers.

## Important Notes

⚠️ **These tests are excluded from the default test suite** because they:
1. Require real OAuth credentials to be configured
2. Make actual HTTP calls to OAuth provider APIs
3. Will fail if environment variables are not properly set
4. Should not run in CI/CD environments without proper secrets management

## Prerequisites

Before running these tests, you must set up OAuth applications with the respective providers and configure the following environment variables:

### Google OAuth
```bash
export GOOGLE_OAUTH_CLIENT_ID="your-google-client-id.apps.googleusercontent.com"
export GOOGLE_OAUTH_CLIENT_SECRET="your-google-client-secret"
```

### GitHub OAuth
```bash
export GITHUB_OAUTH_CLIENT_ID="your-github-client-id"
export GITHUB_OAUTH_CLIENT_SECRET="your-github-client-secret"
```

### Google Calendar Integration
```bash
export GOOGLE_CLIENT_ID="your-google-client-id.apps.googleusercontent.com"
export GOOGLE_CLIENT_SECRET="your-google-client-secret"
export GOOGLE_STATE_SECRET="your-state-secret-for-oauth"
```

## Running the Tests

### Run All OAuth Integration Tests
```bash
mix test --only oauth_integration
```

### Run All Calendar Integration Tests
```bash
mix test --only calendar_integration
```

### Run Google OAuth Tests Only
```bash
mix test --only oauth_integration test/tymeslot_web/integration/google_oauth_integration_test.exs
```

### Run Google Calendar Integration Tests Only
```bash
mix test --only calendar_integration test/tymeslot_web/integration/google_calendar_integration_test.exs
```

### Run GitHub OAuth Tests Only
```bash
mix test --only oauth_integration test/tymeslot_web/integration/github_oauth_integration_test.exs
```

### Run Specific Test Cases
```bash
# Test only environment variable validation
mix test --only oauth_integration -k "environment variables are configured"

# Test only OAuth URL generation
mix test --only oauth_integration -k "can generate valid OAuth authorization URL"
```

## What These Tests Validate

### Environment Configuration
- ✅ OAuth client ID and secret are set
- ✅ OAuth client ID format is valid
- ✅ OAuth client secret is not empty

### OAuth Flow Setup
- ✅ Authorization URLs are correctly generated
- ✅ OAuth clients are properly configured
- ✅ Callback URLs are correctly formatted
- ✅ Required scopes are included

### API Integration
- ✅ Token exchange endpoints are reachable
- ✅ User info endpoints are correctly configured
- ✅ API headers are properly set

### Security & Rate Limiting
- ✅ CSRF state parameters are generated and validated
- ✅ Rate limiting is properly configured
- ✅ Error handling works correctly

## Expected Test Results

### With Proper Configuration
When OAuth credentials are properly configured, you should see output like:
```
............................
Finished in 2.3 seconds
28 tests, 0 failures
```

### Without Configuration
When environment variables are missing, you'll see failures like:
```
1) test environment variables are configured (TymeslotWeb.Integration.GoogleOAuthIntegrationTest)
   ** (ExUnit.AssertionError)
   GOOGLE_OAUTH_CLIENT_ID environment variable is not set
```

### With Invalid Configuration
When credentials are invalid, token exchange tests will fail with OAuth errors, which is expected and validates that the setup is working (the provider is rejecting invalid credentials correctly).

## Troubleshooting

### Google OAuth Issues
- Ensure your OAuth app is configured for the correct redirect URI
- Verify that the OAuth consent screen is properly configured
- Check that the Google OAuth API is enabled in your Google Cloud Console

### GitHub OAuth Issues
- Ensure your OAuth app's Authorization callback URL matches your test environment
- Verify that your OAuth app is not suspended or restricted
- Check that the OAuth app has the correct permissions

### General Issues
- Ensure your test environment has internet access
- Verify that no firewalls are blocking OAuth provider endpoints
- Check that environment variables are properly exported in your shell

## Integration with CI/CD

These tests should **not** be run in standard CI/CD pipelines unless:
1. You have securely configured OAuth credentials as secrets
2. Your CI environment allows outbound HTTPS requests to OAuth providers
3. You have separate OAuth apps configured for testing environments

To exclude them from CI, ensure your CI command uses the default test configuration:
```bash
mix test  # OAuth integration tests are excluded by default
```