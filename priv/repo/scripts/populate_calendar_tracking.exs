# Script to populate calendar tracking fields for existing meetings
# Since we only have test data, we'll leave them as NULL which is acceptable
# The system will handle NULL values gracefully by falling back to the first available calendar

alias Tymeslot.Repo
alias Tymeslot.DatabaseSchemas.MeetingSchema
alias Tymeslot.DatabaseSchemas.UserSchema
alias Tymeslot.DatabaseQueries.CalendarIntegrationQueries

IO.puts("Checking existing meetings for calendar tracking data...")

# Get all meetings
meetings = Repo.all(MeetingSchema)
IO.puts("Found #{length(meetings)} meetings")

# Count meetings with NULL calendar tracking
null_calendar_count = 
  meetings
  |> Enum.filter(&(is_nil(&1.calendar_integration_id)))
  |> length()

IO.puts("Meetings without calendar tracking: #{null_calendar_count}")

# For test purposes, let's show what would happen if we wanted to populate them
# We won't actually do it since NULL values are handled gracefully

if null_calendar_count > 0 do
  IO.puts("\nThese meetings will use the fallback behavior:")
  IO.puts("- For updates/deletes: Will use the first available calendar integration")
  IO.puts("- This is acceptable for test data")
  
  # Show a sample of affected meetings
  meetings
  |> Enum.filter(&(is_nil(&1.calendar_integration_id)))
  |> Enum.take(5)
  |> Enum.each(fn meeting ->
    IO.puts("  - Meeting #{meeting.uid}: #{meeting.title}")
  end)
end

IO.puts("\nNo action needed. The system handles NULL values gracefully.")
IO.puts("New meetings will properly track their calendar integration.")