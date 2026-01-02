defmodule TymeslotWeb.Live.Dashboard.Meetings.Loader do
  @moduledoc false

  alias Tymeslot.Meetings
  alias Tymeslot.Pagination.CursorPage

  @spec list_meetings_for_user(String.t(), map()) :: {:ok, list()} | {:error, term()}
  def list_meetings_for_user(filter, current_user) do
    case list_meetings_page_for_user(filter, current_user, 20, nil) do
      {:ok, %CursorPage{items: items}} -> {:ok, items}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec list_meetings_page_for_user(String.t(), map(), pos_integer(), String.t() | nil) ::
          {:ok, CursorPage.t(map())} | {:error, term()}
  def list_meetings_page_for_user(filter, current_user, per_page, after_cursor) do
    user_id = current_user.id

    opts = [per_page: per_page]
    opts = if after_cursor, do: Keyword.put(opts, :after, after_cursor), else: opts

    opts =
      case filter do
        "upcoming" -> Keyword.put(opts, :time_filter, :upcoming)
        "past" -> Keyword.put(opts, :time_filter, :past)
        "cancelled" -> Keyword.put(opts, :status, "cancelled")
        _ -> opts
      end

    Meetings.list_user_meetings_cursor_page_by_id(user_id, opts)
  rescue
    e -> {:error, e}
  end
end
