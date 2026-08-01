defmodule Tymeslot.Mailer do
  @moduledoc """
  The mailer. Every delivery path in both repos (`Tymeslot.Emails.Delivery`,
  the SaaS `EmailService` and its onboarding/announcement workers) ends up
  calling `deliver/1` or `deliver/2` here, which makes this module the single
  choke point where the tracking category a builder declared gets translated
  into provider-specific options for whichever adapter is actually configured.

  Builders stay pure: they call `put_tracking/2` (see
  `Tymeslot.Emails.Shared.MjmlEmail.base_email/1`) to declare the semantic
  category without reading config or knowing the adapter. `deliver/2` reads
  it back via `tracking/1`, resolves the adapter, and applies
  `Tymeslot.Mailer.Providers.tracking_options/2` immediately before handing
  the email to Swoosh.
  """

  use Swoosh.Mailer, otp_app: :tymeslot

  import Swoosh.Email, only: [put_private: 3, put_provider_option: 3]

  alias Tymeslot.Mailer.Providers

  @tracking_key :tymeslot_tracking

  @doc """
  Stashes a tracking category on an email under construction. The category
  is validated at build time — an unknown atom raises `FunctionClauseError`
  here rather than surfacing as a silent no-op or a delivery-time crash.
  """
  @spec put_tracking(Swoosh.Email.t(), Providers.tracking()) :: Swoosh.Email.t()
  def put_tracking(%Swoosh.Email{} = email, category)
      when category in [:transactional, :lifecycle, :marketing] do
    put_private(email, @tracking_key, category)
  end

  @doc "Reads back the tracking category stashed by `put_tracking/2`, if any."
  @spec tracking(Swoosh.Email.t()) :: Providers.tracking() | nil
  def tracking(%Swoosh.Email{private: private}), do: private[@tracking_key]

  @doc """
  Delivers an email. Applies the tracking options implied by the email's
  tracking category, if any, for whichever adapter this delivery resolves
  to, then hands off to Swoosh's generated `deliver/2`.
  """
  @spec deliver(Swoosh.Email.t(), Keyword.t()) :: {:ok, term()} | {:error, term()}
  def deliver(email, config \\ [])

  def deliver(%Swoosh.Email{} = email, config) do
    email
    |> apply_tracking(config)
    |> super(config)
  end

  @spec apply_tracking(Swoosh.Email.t(), Keyword.t()) :: Swoosh.Email.t()
  defp apply_tracking(%Swoosh.Email{} = email, config) do
    case tracking(email) do
      nil ->
        email

      category ->
        adapter = config |> parse_config() |> Keyword.get(:adapter)

        adapter
        |> Providers.tracking_options(category)
        |> Enum.reduce(email, fn {option, value}, email ->
          put_provider_option(email, option, value)
        end)
    end
  end

  @doc """
  The API-key-based providers (Postmark, SendGrid, Mailgun, AhaSend), as a
  presentation-safe projection: name, label, and every environment variable
  the provider reads (required and optional). Callers that only need to
  describe these providers to a user — the SaaS docs pages — should read
  this instead of filtering `Providers.all/0` themselves, so the internal
  entry shape (`required_config`, `kind`, `probe`, `dev_only`, ...) never
  leaks past this boundary.
  """
  @spec api_providers() :: [%{name: Providers.name(), label: String.t(), env_vars: [String.t()]}]
  def api_providers do
    for {name, entry} <- Providers.all(), entry.kind == :api do
      %{
        name: name,
        label: entry.label,
        env_vars: Map.values(entry.env_vars) ++ entry.optional_env_vars
      }
    end
  end
end
