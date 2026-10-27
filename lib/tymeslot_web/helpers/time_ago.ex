defmodule TymeslotWeb.Helpers.TimeAgo do
  @moduledoc """
  How long ago something happened, as the unit and count a sentence names it
  by: "just now", or so many minutes, hours or days.

  It deliberately returns no words. A relative phrase dropped into a sentence
  ("Last synced %{time}") cannot be translated well: languages inflect the
  verb, the count and the unit together, so each place that says how long ago
  writes its whole sentence as one plural msgid and picks the form from this.
  """

  alias Tymeslot.Clock

  @type t :: :just_now | {:minutes | :hours | :days, pos_integer()}

  @doc "How long before `now` `datetime` was; a moment in the future is `:just_now`."
  @spec since(DateTime.t(), DateTime.t()) :: t()
  def since(%DateTime{} = datetime, now \\ Clock.utc_now()) do
    seconds = DateTime.diff(now, datetime)

    cond do
      seconds < 60 -> :just_now
      seconds < 3600 -> {:minutes, div(seconds, 60)}
      seconds < 86_400 -> {:hours, div(seconds, 3600)}
      true -> {:days, div(seconds, 86_400)}
    end
  end
end
