defmodule Tymeslot.Infrastructure.Logging.PathMasker do
  @moduledoc """
  Masks the path segments of a URL or request path that look like a bearer
  capability, replacing each with `:id`.

  Several public routes carry their authorisation in the path: a meeting's
  uid alone lets its holder cancel or reschedule it
  (`/:username/meeting/:meeting_uid/cancel`), and a meeting request or poll
  is opened by the token in its link (`/meeting-request/:token`). A path
  copied into an error record or an alert email would hand that capability
  to whoever reads it.

  The rule is by shape, so it needs no knowledge of the router: a UUID, or a
  segment of 20 or more URL-safe characters (`A-Z a-z 0-9 _ -`), which is
  what random tokens are encoded as. Ordinary segments such as
  `dashboard`, a username or a meeting type's slug are kept. A long, readable
  slug can be masked too; losing it costs a little context, while keeping a
  token would leak it.

  Only the path is touched; a query string or fragment is kept as it is (see
  `Tymeslot.Infrastructure.Logging.Redactor` for query parameters).
  """

  @mask ":id"
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  @token ~r/\A[A-Za-z0-9_-]{20,}\z/

  @doc """
  Returns `path` (a request path or a full URL) with capability-shaped
  segments replaced by `:id`. Anything that is not a binary is returned
  unchanged.

      iex> Tymeslot.Infrastructure.Logging.PathMasker.mask(
      ...>   "/jane/meeting/0b7e1f3a-4c1d-4a8e-9f3b-2d6c8e1a5b7c/cancel"
      ...> )
      "/jane/meeting/:id/cancel"
  """
  @spec mask(term()) :: term()
  def mask(path) when is_binary(path) do
    {path_part, rest} =
      case :binary.match(path, ["?", "#"]) do
        {index, _length} -> :erlang.split_binary(path, index)
        :nomatch -> {path, ""}
      end

    masked =
      path_part
      |> String.split("/")
      |> Enum.map_join("/", &mask_segment/1)

    masked <> rest
  end

  def mask(other), do: other

  defp mask_segment(segment) do
    if Regex.match?(@uuid, segment) or Regex.match?(@token, segment),
      do: @mask,
      else: segment
  end
end
