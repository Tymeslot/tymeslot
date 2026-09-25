defmodule Tymeslot.Integrations.Calendar.Nextcloud.Login do
  @moduledoc """
  Hands a Nextcloud calendar integration's server and login to another part of
  the product that talks to the same Nextcloud, so the organiser does not type
  them twice.

  A copy, never a link: the receiving integration stores its own credentials
  and is deleted, reconnected and re-encrypted on its own. The server comes back
  as its root, with the CalDAV path a calendar integration may carry stripped.
  """

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.Nextcloud.Provider
  alias Tymeslot.Integrations.Calendar.Shared.PathUtils

  @type login :: %{server_url: String.t(), username: String.t(), password: String.t()}

  @doc "The user's active Nextcloud calendar integrations, by id and name."
  @spec list(pos_integer()) :: [%{id: pos_integer(), name: String.t()}]
  def list(user_id) do
    nextcloud = nextcloud()

    user_id
    |> CalendarIntegrationQueries.list_all_for_user()
    |> Enum.filter(&match?(%{provider: ^nextcloud, is_active: true}, &1))
    |> Enum.map(&%{id: &1.id, name: &1.name})
  end

  @doc "The server root, login name and password of one of the user's active Nextcloud calendar integrations."
  @spec fetch(pos_integer(), pos_integer()) :: {:ok, login()} | {:error, :not_found}
  def fetch(integration_id, user_id) do
    nextcloud = nextcloud()

    case CalendarIntegrationQueries.get_for_user(integration_id, user_id) do
      {:ok,
       %{
         provider: ^nextcloud,
         is_active: true,
         base_url: base_url,
         username: username,
         password: password
       }}
      when is_binary(base_url) and is_binary(username) and is_binary(password) ->
        {:ok,
         %{
           server_url: PathUtils.normalize_base_url(base_url),
           username: username,
           password: password
         }}

      _other ->
        {:error, :not_found}
    end
  end

  # Read at runtime rather than into a module attribute, so this module does
  # not take a compile-time dependency on the provider.
  defp nextcloud, do: Atom.to_string(Provider.provider_type())
end
