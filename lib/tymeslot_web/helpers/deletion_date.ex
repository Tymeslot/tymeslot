defmodule TymeslotWeb.Helpers.DeletionDate do
  @moduledoc """
  A scheduled deletion moment as the date the user sees: in the current
  locale, on the user's own calendar day. Shared by the restore page and the
  account settings modal and flash, so they can never name different days.
  """

  alias Tymeslot.Auth
  alias TymeslotWeb.Helpers.LocaleFormat

  @spec format(DateTime.t(), Ecto.Schema.t()) :: String.t()
  def format(%DateTime{} = at, user) do
    at
    |> Auth.deletion_local_date(user)
    |> LocaleFormat.format_date(Gettext.get_locale(TymeslotWeb.Gettext))
  end
end
