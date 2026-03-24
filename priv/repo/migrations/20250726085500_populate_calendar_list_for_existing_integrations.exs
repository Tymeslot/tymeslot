defmodule Tymeslot.Repo.Migrations.PopulateCalendarListForExistingIntegrations do
  use Ecto.Migration

  # NOTE: Originally used CalendarIntegrationSchema directly, which broke
  # `mix ecto.reset` when the schema gained new columns in later migrations.
  # Rewritten to use raw SQL to avoid compile-time coupling to the live schema.

  def up do
    execute(fn ->
      # Fetch only the columns we need — immune to future schema changes
      {:ok, result} =
        repo().query("""
        SELECT id, provider, calendar_paths
        FROM calendar_integrations
        """)

      Enum.each(result.rows, fn [id, provider, calendar_paths] ->
        {calendar_list, default_booking_calendar_id} =
          build_calendar_data(provider, calendar_paths)

        if calendar_list != [] do
          encoded = Jason.encode!(calendar_list)

          repo().query!(
            """
            UPDATE calendar_integrations
            SET calendar_list = $1::jsonb,
                default_booking_calendar_id = $2
            WHERE id = $3
            """,
            [encoded, default_booking_calendar_id, id]
          )
        end
      end)
    end)
  end

  def down do
    execute(fn ->
      repo().query!("""
      UPDATE calendar_integrations
      SET calendar_list = '[]'::jsonb,
          default_booking_calendar_id = NULL
      """)
    end)
  end

  defp build_calendar_data("google", _calendar_paths) do
    list = [
      %{
        "id" => "primary",
        "name" => "Primary Calendar",
        "primary" => true,
        "selected" => true
      }
    ]

    {list, "primary"}
  end

  defp build_calendar_data("outlook", _calendar_paths) do
    list = [
      %{
        "id" => "default",
        "name" => "Default Calendar",
        "primary" => true,
        "selected" => true
      }
    ]

    {list, "default"}
  end

  defp build_calendar_data(provider, calendar_paths)
       when provider in ["caldav", "nextcloud"] and is_list(calendar_paths) and
              calendar_paths != [] do
    list =
      Enum.map(calendar_paths, fn path ->
        %{
          "id" => path,
          "path" => path,
          "name" => extract_calendar_name(path),
          "selected" => true
        }
      end)

    default_id =
      case list do
        [first | _] -> first["id"]
        _ -> nil
      end

    {list, default_id}
  end

  defp build_calendar_data(_provider, _calendar_paths), do: {[], nil}

  defp extract_calendar_name(path) do
    path
    |> String.split("/")
    |> List.last()
    |> String.replace(".ics", "")
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
