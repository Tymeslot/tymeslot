defmodule Tymeslot.OAuthFlowHelpers do
  @moduledoc """
  The `state` an integration OAuth callback test presents: signed as the
  provider's authorisation URL signs it, and naming a pending PKCE flow
  started for the user, so the callback can consume it.
  """

  alias Tymeslot.Integrations.Shared.OAuth.PendingFlow
  alias Tymeslot.Integrations.Shared.OAuth.State

  @doc """
  Starts `user_id`'s `provider` flow and returns a state for it signed with
  `secret`. Options: `:integration_id`, `:return_to`.
  """
  @spec flow_state(pos_integer(), atom(), String.t(), keyword()) :: String.t()
  def flow_state(user_id, provider, secret, opts \\ []) do
    {:ok, flow} = PendingFlow.start(user_id, provider)

    State.generate(user_id, secret, Keyword.get(opts, :integration_id),
      return_to: Keyword.get(opts, :return_to),
      nonce: flow.nonce
    )
  end
end
