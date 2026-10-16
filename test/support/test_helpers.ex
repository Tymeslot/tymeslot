defmodule Tymeslot.TestHelpers do
  @moduledoc """
  Centralized import point for all test helper modules.

  This module provides a convenient way to import all commonly used test utilities
  in a single line, reducing boilerplate and making it easier to discover what
  helpers are available.

  ## Why Use This?

  Instead of importing helpers individually in every test:

      import Tymeslot.Factory
      import Tymeslot.TestFixtures
      import Tymeslot.AuthTestHelpers
      import Tymeslot.TestMocks
      import Tymeslot.TestAssertions
      import Tymeslot.ConfigTestHelpers
      import Tymeslot.TestHelpers.Eventually

  You can write:

      use Tymeslot.TestHelpers

  ## What Gets Imported?

  By default, `use Tymeslot.TestHelpers` imports:

  - **Factory** - ExMachina factories for creating test data (`insert/1`, `build/1`)
  - **TestFixtures** - Complex scenario builders with business logic
  - **TestMocks** - Centralized mock setup functions for Mox
  - **TestAssertions** - Behavioral assertions for LiveView and forms
  - **ConfigTestHelpers** - Temporary config changes with automatic cleanup
  - **Eventually** - Deterministic polling helper replacing `Process.sleep`

  ## Optional Imports

  Some helpers are domain-specific and only imported when requested:

  ### Authentication Helpers (Imported by Default)

      use Tymeslot.TestHelpers  # auth: true is default

  Provides: `log_in_user/2`, `create_oauth_state/1`, `assert_email_sent/1`, etc.

  To exclude:

      use Tymeslot.TestHelpers, auth: false

  ### Payment Helpers (Opt-in)

      use Tymeslot.TestHelpers, payment: true

  Provides: `mock_stripe_checkout_session/1`, `generate_stripe_signature/2`,
  `create_test_transaction/1`, etc.

  ### Email Helpers (Opt-in)

      use Tymeslot.TestHelpers, email: true

  Provides: `create_appointment_details/1` with 40+ customizable fields for
  email template testing.

  ### Availability Helpers (Opt-in)

      use Tymeslot.TestHelpers, availability: true

  Provides: `create_availability_profile/1`, `create_availability_day/1`,
  `set_default_availability/1`, etc.

  ## Full Example

      defmodule Tymeslot.BookingFlowTest do
        use Tymeslot.DataCase, async: true
        use Tymeslot.TestHelpers, payment: true, email: true

        setup :verify_on_exit!

        test "books meeting and sends confirmation" do
          user = create_user_fixture()
          setup_all_mocks()

          # Use factory to create test data
          profile = insert(:profile, user: user)

          # Use config helper
          with_config(:tymeslot, video_provider: :mirotalk)

          # ... test logic

          # Use eventually for async operations
          eventually(fn ->
            assert_email_sent(to: user.email)
          end)
        end
      end

  ## Import Hierarchy

  The import order is carefully chosen to avoid naming conflicts:

  1. Factory (base data creation)
  2. TestFixtures (complex scenarios)
  3. ConfigTestHelpers (config management)
  4. TestMocks (mock setup)
  5. Eventually (polling helper)
  6. TestAssertions (assertions that might override ExUnit)
  7. Domain-specific helpers last (auth, payment, email, etc.)

  ## Customization

  If you need fine-grained control, import modules directly:

      import Tymeslot.Factory
      import Tymeslot.TestFixtures, only: [create_user_fixture: 0, create_meeting_fixture: 1]
      import Tymeslot.ConfigTestHelpers
  """

  defmacro __using__(opts \\ []) do
    # Parse options with defaults
    auth = Keyword.get(opts, :auth, true)
    payment = Keyword.get(opts, :payment, false)
    email = Keyword.get(opts, :email, false)
    availability = Keyword.get(opts, :availability, false)
    worker = Keyword.get(opts, :worker, false)

    quote do
      # Core helpers - always imported
      import Tymeslot.Factory
      import Tymeslot.TestFixtures
      import Tymeslot.TestMocks
      import Tymeslot.ConfigTestHelpers
      import Tymeslot.TestHelpers.Eventually

      # TestAssertions last to avoid conflicts with ExUnit assertions
      import Tymeslot.TestAssertions

      # Conditionally import domain-specific helpers
      if unquote(auth) do
        import Tymeslot.AuthTestHelpers
      end

      if unquote(payment) do
        import Tymeslot.PaymentTestHelpers
      end

      if unquote(email) do
        import Tymeslot.EmailTestHelpers
      end

      if unquote(availability) do
        import Tymeslot.AvailabilityTestHelpers
      end

      if unquote(worker) do
        import Tymeslot.WorkerTestHelpers
      end
    end
  end
end
