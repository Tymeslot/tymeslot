defmodule Tymeslot.Integrations.Video.MeetingLinkTemplate do
  @moduledoc """
  Judges the `{{meeting_id}}` placeholder of a custom integration's stored
  meeting link.

  Links saved before the placeholder was validated can still hold one that
  room creation never replaces (`{meeting_id}`, `{{Meeting_ID}}`, an escaped
  `%7B%7Bmeeting_id%7D%7D`), so every booking on the integration silently
  shares one room. Such a link keeps working as a static room, so it is only
  reported to the owner, never blocked or rewritten.
  """

  alias Tymeslot.Integrations.Video.InputValidation

  @doc """
  Whether a custom integration's stored meeting link carries a placeholder the
  save form would refuse.

  Judged by the rule a save enforces
  (`InputValidation.validate_meeting_url_template/1`: the link as typed and its
  percent-decoded reading), so it flags exactly the links the edit form would
  send back. A bare `?meeting_id=123` and a Teams link whose decoded context
  carries braces both pass, as they do on save. Any other provider is never
  flagged.
  """
  @spec invalid?(map()) :: boolean()
  def invalid?(%{provider: "custom", custom_meeting_url: url}) when is_binary(url),
    do: match?({:error, _message}, InputValidation.validate_meeting_url_template(url))

  def invalid?(_integration), do: false
end
