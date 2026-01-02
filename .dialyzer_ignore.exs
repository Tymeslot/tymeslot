[
  # False positive: Repo-backed lookup returns {:ok, profile} in tests, but Dialyzer
  # assumes {:error, :not_found} only because database contents are opaque.
  {"lib/tymeslot/profiles.ex", "The pattern can never match the type {:error, :not_found}."},
  {"lib/tymeslot/profiles.ex", "Function build_organizer_context/2 will never be called."},
  {"lib/tymeslot/profiles.ex", "Function meeting_types_for_profile/1 will never be called."}
]
