defmodule Tymeslot.Integrations.Calendar.CalendarIntegrationRefQueries do
  @moduledoc """
  Calendar integrations read as references only, never loading their
  credentials, for callers that need to name an integration rather than
  talk to its provider. `CalendarIntegrationQueries` loads the whole row.
  """

  import Ecto.Query

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Repo

  @doc """
  The id and provider of one of the user's active integrations: enough to
  ask for its sync. `nil` when the id is not the user's, or the integration
  is not active.
  """
  @spec get_active(integer(), integer()) :: %{id: integer(), provider: String.t()} | nil
  def get_active(user_id, id) do
    CalendarIntegrationSchema
    |> where([c], c.id == ^id and c.user_id == ^user_id and c.is_active == true)
    |> select([c], %{id: c.id, provider: c.provider})
    |> Repo.one()
  end
end
