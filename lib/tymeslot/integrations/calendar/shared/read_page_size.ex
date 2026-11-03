defmodule Tymeslot.Integrations.Calendar.Shared.ReadPageSize do
  @moduledoc """
  How many events a provider read asks for per page.

  Each provider read has its own default, sized so that an ordinary calendar
  fits on one page. `config :tymeslot, :calendar_read_page_size, n` overrides
  every one of them, which is how `mix calendar_audit` makes a read of three
  events span two pages: a pagination bug cannot show on a calendar that
  never needs a second page. Unset, the defaults apply.
  """

  @doc "The page size for a read whose own default is `default`."
  @spec get(pos_integer()) :: pos_integer()
  def get(default) when is_integer(default) and default > 0 do
    case Application.get_env(:tymeslot, :calendar_read_page_size) do
      size when is_integer(size) and size > 0 -> size
      _unset -> default
    end
  end
end
