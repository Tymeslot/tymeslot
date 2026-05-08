defmodule Tymeslot.Announcements.Catalog do
  @moduledoc """
  Core's list of feature announcements. Add a new entry every time a
  noteworthy user-facing feature ships.

  Each entry must use `gettext/1` for translatable strings so locales other
  than `en` are picked up. The `:key` MUST be globally unique and never
  change after release — it is the identity used in `user_seen_announcements`.
  """

  alias Tymeslot.Announcements.Announcement

  @spec list() :: [Announcement.t()]
  def list, do: []
end
