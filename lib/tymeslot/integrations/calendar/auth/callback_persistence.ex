defmodule Tymeslot.Integrations.Calendar.CallbackPersistence do
  @moduledoc """
  Turns the tokens of a completed Google or Outlook calendar OAuth callback
  into the user's integration: reconnects the one the flow was started for,
  or the one already connected to the same provider account, or creates one.

  The two providers differ only in the data in `@providers`; the account
  matching, reactivation, insert-race protection and calendar discovery are
  shared, so a change to any of them reaches both.
  """

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Integrations.Calendar.Primary
  alias Tymeslot.Integrations.Shared.OAuth.AccountMatch

  @providers %{
    "google" => %{
      label: "Google",
      name: "Google Calendar",
      base_url: "https://www.googleapis.com/calendar/v3"
    },
    "outlook" => %{
      label: "Outlook",
      name: "Outlook Calendar",
      base_url: "https://graph.microsoft.com/v1.0"
    }
  }

  @type provider :: String.t()

  @typedoc """
  The callback's result: the tokens, and the provider account they belong to
  (nil when the provider's id token could not be read).
  """
  @type tokens :: %{
          required(:access_token) => String.t(),
          required(:refresh_token) => String.t() | nil,
          required(:expires_at) => DateTime.t(),
          required(:scope) => String.t() | nil,
          required(:provider_account_id) => String.t() | nil,
          required(:provider_account_email) => String.t() | nil,
          optional(atom()) => term()
        }

  @doc """
  Creates or reconnects `user_id`'s `provider` integration from `tokens`.

  With an `integration_id` (a reconnect started from that integration) the
  tokens must belong to the account it is connected to. Otherwise the
  provider account picks the integration, and a callback whose account
  cannot be identified creates one only when the user has none for the
  provider yet, rather than overwrite one that may belong to another account.

  Connecting is wanting the integration active, so every write activates it.
  """
  @spec upsert(provider(), pos_integer(), pos_integer() | nil, tokens()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, term()}
  def upsert(provider, user_id, integration_id, tokens) when is_map_key(@providers, provider) do
    token_attrs = %{
      access_token: tokens.access_token,
      refresh_token: tokens.refresh_token,
      token_expires_at: tokens.expires_at,
      oauth_scope: tokens.scope,
      is_active: true,
      provider_account_id: tokens.provider_account_id,
      provider_account_email: tokens.provider_account_email
    }

    match(provider, user_id, integration_id, tokens.provider_account_id, token_attrs)
  end

  # New connection with a known account
  defp match(provider, user_id, nil, account_id, token_attrs) when is_binary(account_id) do
    case CalendarIntegrationQueries.get_by_account_for_user(user_id, provider, account_id) do
      {:ok, existing} -> reconnect(existing, token_attrs)
      {:error, :not_found} -> create(provider, user_id, account_id, token_attrs)
    end
  end

  # No account id: the user already has an integration for the provider, but
  # nothing says which account this callback belongs to. Reject rather than
  # silently overwrite.
  defp match(provider, user_id, nil, nil, token_attrs) do
    case CalendarIntegrationQueries.get_by_user_and_provider(user_id, provider) do
      {:ok, _existing} ->
        {:error,
         "Could not identify your #{@providers[provider].label} account. Please try again. " <>
           "If the problem persists, remove and re-add the integration."}

      {:error, :not_found} ->
        create(provider, user_id, nil, token_attrs)
    end
  end

  # Re-authorisation of a specific integration
  defp match(_provider, user_id, integration_id, account_id, token_attrs) do
    case Management.fetch_integration_for_user(integration_id, user_id) do
      {:ok, existing} ->
        AccountMatch.verify_account_match(existing, account_id, fn ->
          reconnect(existing, token_attrs)
        end)

      {:error, :not_found} ->
        {:error, "Integration not found"}
    end
  end

  defp create(provider, user_id, account_id, token_attrs) do
    %{name: name, base_url: base_url} = @providers[provider]

    attrs =
      Map.merge(token_attrs, %{
        user_id: user_id,
        name: name,
        provider: provider,
        base_url: base_url
      })

    create_fn = fn -> Management.insert_integration(attrs) end

    result =
      if is_binary(account_id) do
        create_or_reactivate(provider, user_id, account_id, token_attrs, create_fn)
      else
        create_fn.()
      end

    with {:ok, integration} <- result, do: configure_if_unlisted(integration)
  end

  # A deactivated integration for the same account is brought back rather
  # than duplicated, and an insert that loses a race to a concurrent callback
  # for the same account reconnects the row that won.
  defp create_or_reactivate(provider, user_id, account_id, token_attrs, create_fn) do
    AccountMatch.find_or_create_with_reactivation(
      fn ->
        CalendarIntegrationQueries.get_any_by_account_for_user(user_id, provider, account_id)
      end,
      &reconnect(&1, token_attrs, :always),
      fn ->
        AccountMatch.create_with_race_protection(
          create_fn,
          fn ->
            CalendarIntegrationQueries.get_by_account_for_user(user_id, provider, account_id)
          end,
          &reconnect(&1, token_attrs)
        )
      end
    )
  end

  # A reconnect proves the grant, so, as for credentials re-entered by hand,
  # the integration's health streak is reset: a calendar reconnected after
  # failing must not be paused again by the auto-pause sweep for failures from
  # before it. A reconnect can also reactivate an integration that was paused,
  # which may have been the user's only calendar and so lost its place as the
  # primary; the activation rule adopts it again, under the primary lock and
  # before discovery goes to the network.
  defp reconnect(existing, token_attrs, discovery \\ :if_unlisted) do
    with {:ok, updated} <- Management.reconnect_integration(existing, token_attrs) do
      discover(updated, discovery)
    end
  end

  # A reactivated integration has been out of use for a while, so its
  # calendar list is read afresh; an active one only when it has none yet.
  defp discover(integration, :always),
    do: Primary.discover_and_configure_calendars(integration)

  defp discover(integration, :if_unlisted), do: configure_if_unlisted(integration)

  defp configure_if_unlisted(%{calendar_list: []} = integration),
    do: Primary.discover_and_configure_calendars(integration)

  defp configure_if_unlisted(integration), do: {:ok, integration}
end
