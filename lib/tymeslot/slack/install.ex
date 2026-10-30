defmodule Tymeslot.Slack.Install do
  @moduledoc """
  Finishes the Slack app install: verifies the OAuth callback Slack
  redirected back with and stores the workspace install as a pending
  integration awaiting its channel. Reached through
  `Tymeslot.Slack.complete_oauth/2` and
  `Tymeslot.Slack.complete_oauth_callback/4`; the protocol itself (authorize
  URL, state token, code exchange) is `Tymeslot.Slack.OAuth`.
  """

  alias Tymeslot.Features
  alias Tymeslot.Repo
  alias Tymeslot.Slack
  alias Tymeslot.Slack.{OAuth, SlackIntegrationSchema, SlackQueries}

  @doc """
  Persists a partial OAuth-completed integration record using `oauth_init_changeset/2`.

  Takes the install map returned by `Tymeslot.Slack.OAuth.exchange_code/2`
  and maps it onto the integration: the display name defaults to the workspace
  name so the dashboard has something to show before the user edits it, and
  the integration subscribes to every event until the user prunes the list.

  The returned integration is in `:pending_oauth` status until
  `Tymeslot.Slack.set_channel/2` is called with the user's channel selection.
  """
  @spec complete_oauth(integer(), OAuth.install()) ::
          {:ok, SlackIntegrationSchema.t()}
          | {:error,
             Ecto.Changeset.t()
             | :insufficient_plan
             | :feature_access_checker_failed
             | :feature_disabled}
  def complete_oauth(user_id, install) do
    if Slack.slack_enabled?() do
      with :ok <- Features.check_access(user_id, :automations_allowed) do
        stub_attrs = install_to_attrs(user_id, install)

        transaction_result =
          Repo.transaction(fn ->
            SlackQueries.delete_pending_stubs(user_id)

            case SlackQueries.create_oauth_stub(stub_attrs) do
              {:ok, integration} -> integration
              {:error, changeset} -> Repo.rollback(changeset)
            end
          end)

        case transaction_result do
          {:ok, integration} -> {:ok, integration}
          {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
          {:error, reason} -> {:error, reason}
        end
      end
    else
      {:error, :feature_disabled}
    end
  end

  @doc """
  Completes the OAuth flow Slack redirected back with: checks that OAuth is
  still available (the operator may have removed the Slack app credentials
  since the flow started), verifies the signed `state` was issued to
  `user_id`, exchanges `code`, and stores the pending integration.

  Returns tagged errors for every refusal, never raises.
  """
  @spec complete_oauth_callback(integer(), String.t(), String.t(), String.t()) ::
          {:ok, SlackIntegrationSchema.t()}
          | {:error,
             :oauth_unavailable
             | :invalid_state
             | :expired_state
             | :user_mismatch
             | term()}
  def complete_oauth_callback(user_id, code, state, redirect_uri) do
    with :ok <- check_oauth_available(),
         {:ok, state_user_id} <- OAuth.verify_state(state),
         :ok <- state_issued_to(state_user_id, user_id),
         {:ok, install} <- OAuth.exchange_code(code, redirect_uri) do
      complete_oauth(user_id, install)
    end
  end

  defp check_oauth_available do
    if Slack.oauth_mode_available?(), do: :ok, else: {:error, :oauth_unavailable}
  end

  defp state_issued_to(user_id, user_id), do: :ok
  defp state_issued_to(_state_user_id, _user_id), do: {:error, :user_mismatch}

  defp install_to_attrs(user_id, install) do
    %{
      user_id: user_id,
      app_mode: :oauth,
      name: install[:team_name] || "Slack",
      bot_token: install[:bot_token],
      team_id: install[:team_id],
      team_name: install[:team_name],
      authed_user_id: install[:authed_user_id],
      scope: install[:scope],
      events: Slack.default_events_for_new_integration()
    }
  end
end
