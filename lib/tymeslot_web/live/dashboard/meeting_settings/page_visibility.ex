defmodule TymeslotWeb.Dashboard.MeetingSettings.PageVisibility do
  @moduledoc """
  Where a meeting type is listed, shaped for the meeting type editor's
  Visibility switches and the meeting type cards.

  The profile's own page at `/<username>` is the type's `is_private` flag;
  each booking page is a listing (`Tymeslot.BookingPages.memberships/1`). A type
  listed nowhere is unlisted: bookable only through its direct link.
  """

  @type row :: %{id: String.t(), address: String.t(), checked: boolean()}

  @doc "One row per page, the username's first; none without a type."
  @spec rows(String.t() | nil, [map()], map(), map() | nil) :: [row()]
  def rows(_username, _pages, _memberships, nil), do: []

  def rows(username, pages, memberships, type) do
    listed_on = Map.get(memberships, type.id, MapSet.new())

    [
      %{id: "profile", address: username || "", checked: not type.is_private}
      | Enum.map(pages, fn page ->
          %{
            id: to_string(page.id),
            address: page.slug,
            checked: MapSet.member?(listed_on, page.id)
          }
        end)
    ]
  end

  @doc "Whether a type is on no page at all."
  @spec unlisted?(map(), map()) :: boolean()
  def unlisted?(memberships, type),
    do: type.is_private and not Map.has_key?(memberships, type.id)

  @doc """
  The addresses a type is listed on, for its card. Empty while the profile has
  no booking pages, where the "Unlisted" badge says it all.
  """
  @spec addresses(String.t() | nil, [map()], map(), map()) :: [String.t()]
  def addresses(_username, [], _memberships, _type), do: []

  def addresses(username, pages, memberships, type) do
    username
    |> rows(pages, memberships, type)
    |> Enum.filter(& &1.checked)
    |> Enum.map(& &1.address)
  end
end
