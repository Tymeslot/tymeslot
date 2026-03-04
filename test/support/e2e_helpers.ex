defmodule TymeslotWeb.E2EHelpers do
  @moduledoc """
  Shared browser interaction helpers for E2E tests.
  """

  import Wallaby.Browser
  import Wallaby.Query

  alias Tymeslot.DatabaseSchemas.UserSchema
  alias Tymeslot.Factory
  alias Tymeslot.Profiles

  @default_password "Password123!"

  @doc """
  Returns the default password used by the user factory.
  """
  @spec default_password() :: String.t()
  def default_password, do: @default_password

  @doc """
  Logs in a user via the browser login form.

  Creates a verified user (with onboarding completed and a profile) from the
  given attributes, then navigates to `/auth/login`, fills the form, and waits
  for the dashboard to load.

  Returns `{session, user}`.
  """
  @spec log_in_via_browser(Wallaby.Session.t(), map()) :: {Wallaby.Session.t(), UserSchema.t()}
  def log_in_via_browser(session, user_attrs \\ %{}) do
    user = create_onboarded_user(user_attrs)

    session =
      session
      |> visit("/auth/login")
      |> wait_for_live()
      |> fill_in(text_field("email"), with: user.email)
      |> fill_in(css("#password-input"), with: @default_password)
      |> click(css("button[type='submit']"))
      |> wait_for_dashboard()

    {session, user}
  end

  @doc """
  Waits for LiveView to mount by checking for `[data-phx-main]`.
  """
  @spec wait_for_live(Wallaby.Session.t()) :: Wallaby.Session.t()
  def wait_for_live(session) do
    assert_has(session, css("[data-phx-main]", count: :any, minimum: 1))
  end

  @doc """
  Waits for the dashboard to appear after login.
  """
  @spec wait_for_dashboard(Wallaby.Session.t()) :: Wallaby.Session.t()
  def wait_for_dashboard(session) do
    assert_has(session, css("#dashboard-root"))
  end

  @doc """
  Creates a verified user with onboarding completed and a profile.

  This is the typical starting state for tests that need an authenticated
  user who can access the dashboard without being redirected to onboarding.
  """
  @spec create_onboarded_user(map()) :: UserSchema.t()
  def create_onboarded_user(attrs \\ %{}) do
    user =
      Factory.insert(
        :user,
        Map.merge(
          %{
            onboarding_completed_at: DateTime.utc_now(:second)
          },
          attrs
        )
      )

    {:ok, _profile} = Profiles.get_or_create_profile(user.id)

    user
  end
end
