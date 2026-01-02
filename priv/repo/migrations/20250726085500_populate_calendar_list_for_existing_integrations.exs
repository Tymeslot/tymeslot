defmodule Tymeslot.Repo.Migrations.PopulateCalendarListForExistingIntegrations do
  use Ecto.Migration
  import Ecto.Query
  alias Tymeslot.Repo
  alias Tymeslot.DatabaseSchemas.CalendarIntegrationSchema

  def up do
    # Run this in a separate process to have access to the schema
    execute(fn ->
      integrations = Repo.all(CalendarIntegrationSchema)
      
      Enum.each(integrations, fn integration ->
        calendar_list = case integration.provider do
          "google" ->
            # For Google, default to primary calendar
            [%{
              "id" => "primary",
              "name" => "Primary Calendar",
              "primary" => true,
              "selected" => true
            }]
            
          "outlook" ->
            # For Outlook, use default calendar
            [%{
              "id" => "default",
              "name" => "Default Calendar",
              "primary" => true,
              "selected" => true
            }]
            
          provider when provider in ["caldav", "nextcloud"] ->
            # Convert existing calendar_paths to calendar_list
            if integration.calendar_paths && length(integration.calendar_paths) > 0 do
              Enum.map(integration.calendar_paths, fn path ->
                %{
                  "id" => path,
                  "path" => path,
                  "name" => extract_calendar_name(path),
                  "selected" => true
                }
              end)
            else
              []
            end
            
          _ ->
            []
        end
        
        # Set default booking calendar
        default_booking_calendar_id = case {integration.provider, calendar_list} do
          {"google", _} -> "primary"
          {"outlook", _} -> "default"
          {_, [first | _]} -> first["id"] || first[:id]
          _ -> nil
        end
        
        # Update the integration
        if calendar_list != [] do
          integration
          |> CalendarIntegrationSchema.changeset(%{
            calendar_list: calendar_list,
            default_booking_calendar_id: default_booking_calendar_id
          })
          |> Repo.update()
        end
      end)
    end)
  end

  def down do
    # Clear calendar_list and default_booking_calendar_id
    execute(fn ->
      from(ci in CalendarIntegrationSchema)
      |> Repo.update_all(set: [
        calendar_list: [],
        default_booking_calendar_id: nil
      ])
    end)
  end
  
  defp extract_calendar_name(path) do
    path
    |> String.split("/")
    |> List.last()
    |> String.replace(".ics", "")
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end