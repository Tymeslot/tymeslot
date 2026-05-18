defmodule Tymeslot.Announcements.Catalog do
  @moduledoc """
  Core's canonical, English-only source of feature announcements. Add a new
  entry every time a noteworthy user-facing feature ships.

  Announcement content is intentionally not translated — all entries stay in
  English. The `:key` MUST be globally unique and never change after release
  — it is the identity used in `user_seen_announcements`.
  """

  alias Tymeslot.Announcements.Announcement

  @spec list() :: [Announcement.t()]
  def list, do: []
end
