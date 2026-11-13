defmodule TymeslotWeb.Dashboard.ContactSearchController do
  @moduledoc """
  Contact suggestions for the dashboard's invite fields
  (`assets/js/hooks/contact_suggest.js`): the signed-in host's contacts whose
  name or address contains `q`, from the address books of their calendar
  connections (`Tymeslot.Contacts`).

  A plain request rather than a LiveView event, so a slow address book
  server keeps one request waiting, never the dashboard's LiveView. Rate
  limited per host, since every request may reach their servers.
  """

  use TymeslotWeb, :controller

  alias Tymeslot.Contacts
  alias Tymeslot.Security.RateLimiter

  @spec search(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def search(conn, params) do
    user = conn.assigns.current_user

    case RateLimiter.check(:contact_search, user.id) do
      :ok ->
        contacts = Contacts.search(user.id, to_string(params["q"] || ""))

        conn
        |> put_resp_header("cache-control", "no-store")
        |> json(%{contacts: Enum.map(contacts, &Map.take(&1, [:name, :email]))})

      {:error, _limited, _message} ->
        conn |> put_status(:too_many_requests) |> json(%{contacts: []})

      {:error, _invalid} ->
        conn |> put_status(:bad_request) |> json(%{contacts: []})
    end
  end
end
