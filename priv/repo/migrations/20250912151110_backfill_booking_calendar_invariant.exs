defmodule Tymeslot.Repo.Migrations.BackfillBookingCalendarInvariant do
  use Ecto.Migration

  def up do
    execute(fn ->
      import Ecto.Query
      alias Tymeslot.Repo
      alias Tymeslot.DatabaseSchemas.CalendarIntegrationSchema
      alias Tymeslot.DatabaseSchemas.ProfileSchema

      users = Repo.all(from ci in CalendarIntegrationSchema, select: ci.user_id, distinct: true)

      Enum.each(users, fn user_id ->
        integrations =
          Repo.all(
            from ci in CalendarIntegrationSchema,
              where: ci.user_id == ^user_id,
              order_by: [asc: ci.inserted_at]
          )

        if integrations != [] do
          primary_id =
            Repo.one(
              from p in ProfileSchema,
                where: p.user_id == ^user_id,
                select: p.primary_calendar_integration_id
            )

          with_defaults = Enum.filter(integrations, &(!is_nil(&1.default_booking_calendar_id)))

          chosen =
            cond do
              with_defaults == [] ->
                cond do
                  primary_id != nil -> Enum.find(integrations, &(&1.id == primary_id)) || List.first(integrations)
                  true -> List.first(integrations)
                end

              true ->
                case Enum.find(with_defaults, &(&1.id == primary_id)) do
                  nil -> hd(with_defaults)
                  x -> x
                end
            end

          if chosen do
            chosen_default = chosen.default_booking_calendar_id || resolve_default_calendar_id(chosen)

            if chosen_default do
              # Set chosen default and clear others
              Repo.update_all(
                from(ci in CalendarIntegrationSchema, where: ci.id == ^chosen.id),
                set: [default_booking_calendar_id: chosen_default]
              )

              Repo.update_all(
                from(ci in CalendarIntegrationSchema, where: ci.user_id == ^user_id and ci.id != ^chosen.id),
                set: [default_booking_calendar_id: nil]
              )
            else
              # No resolvable default for chosen; clear others to avoid duplicate defaults
              Repo.update_all(
                from(ci in CalendarIntegrationSchema, where: ci.user_id == ^user_id and ci.id != ^chosen.id),
                set: [default_booking_calendar_id: nil]
              )
            end
          end
        end
      end)
    end)
  end

  def down do
    :ok
  end

  # Local resolution helper (mirrors app logic without depending on app modules)
  defp resolve_default_calendar_id(integration) do
    cal_list = integration.calendar_list || []

    cond do
      is_list(cal_list) and cal_list != [] ->
        primary =
          Enum.find(cal_list, fn cal ->
            (Map.get(cal, "primary") || Map.get(cal, :primary)) == true
          end)

        cond do
          not is_nil(primary) ->
            Map.get(primary, "id") || Map.get(primary, :id) || Map.get(primary, "path") || Map.get(primary, :path)

          true ->
            selected =
              Enum.find(cal_list, fn cal ->
                (Map.get(cal, "selected") || Map.get(cal, :selected)) == true
              end)

            candidate = selected || List.first(cal_list)
            Map.get(candidate, "id") || Map.get(candidate, :id) || Map.get(candidate, "path") || Map.get(candidate, :path)
        end

      integration.provider == "google" -> "primary"
      integration.provider == "outlook" -> "default"
      is_list(integration.calendar_paths) and integration.calendar_paths != [] ->
        List.first(integration.calendar_paths)

      true -> nil
    end
  end
end
