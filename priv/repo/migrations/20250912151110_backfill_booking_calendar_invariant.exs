defmodule Tymeslot.Repo.Migrations.BackfillBookingCalendarInvariant do
  use Ecto.Migration

  # NOTE: Rewritten to use raw table references instead of schema modules.
  # Schema modules evolve over time; referencing them in migrations causes
  # `mix ecto.reset` failures when later migrations add columns.

  def up do
    execute(fn ->
      import Ecto.Query

      users =
        repo().all(
          from(ci in "calendar_integrations", select: ci.user_id, distinct: true)
        )

      Enum.each(users, fn user_id ->
        integrations =
          repo().all(
            from(ci in "calendar_integrations",
              where: ci.user_id == ^user_id,
              order_by: [asc: ci.inserted_at],
              select: %{
                id: ci.id,
                provider: ci.provider,
                calendar_list: ci.calendar_list,
                calendar_paths: ci.calendar_paths,
                default_booking_calendar_id: ci.default_booking_calendar_id
              }
            )
          )

        if integrations != [] do
          primary_id =
            repo().one(
              from(p in "profiles",
                where: p.user_id == ^user_id,
                select: p.primary_calendar_integration_id
              )
            )

          with_defaults =
            Enum.filter(integrations, &(!is_nil(&1.default_booking_calendar_id)))

          chosen = pick_chosen(integrations, with_defaults, primary_id)

          if chosen do
            chosen_default =
              chosen.default_booking_calendar_id || resolve_default_calendar_id(chosen)

            if chosen_default do
              repo().update_all(
                from(ci in "calendar_integrations", where: ci.id == ^chosen.id),
                set: [default_booking_calendar_id: chosen_default]
              )

              repo().update_all(
                from(ci in "calendar_integrations",
                  where: ci.user_id == ^user_id and ci.id != ^chosen.id
                ),
                set: [default_booking_calendar_id: nil]
              )
            else
              repo().update_all(
                from(ci in "calendar_integrations",
                  where: ci.user_id == ^user_id and ci.id != ^chosen.id
                ),
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

  defp pick_chosen(integrations, with_defaults, primary_id) do
    cond do
      with_defaults == [] ->
        if primary_id,
          do: Enum.find(integrations, &(&1.id == primary_id)) || List.first(integrations),
          else: List.first(integrations)

      true ->
        case Enum.find(with_defaults, &(&1.id == primary_id)) do
          nil -> hd(with_defaults)
          x -> x
        end
    end
  end

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
            Map.get(primary, "id") || Map.get(primary, :id) ||
              Map.get(primary, "path") || Map.get(primary, :path)

          true ->
            selected =
              Enum.find(cal_list, fn cal ->
                (Map.get(cal, "selected") || Map.get(cal, :selected)) == true
              end)

            candidate = selected || List.first(cal_list)

            Map.get(candidate, "id") || Map.get(candidate, :id) ||
              Map.get(candidate, "path") || Map.get(candidate, :path)
        end

      integration.provider == "google" ->
        "primary"

      integration.provider == "outlook" ->
        "default"

      is_list(integration.calendar_paths) and integration.calendar_paths != [] ->
        List.first(integration.calendar_paths)

      true ->
        nil
    end
  end
end
