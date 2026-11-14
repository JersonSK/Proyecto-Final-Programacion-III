defmodule Emergencias.Application do
  @moduledoc """
  Punto de arranque y raíz del árbol de supervisión:

      Emergencias.Supervisor (one_for_one)
      ├── Registry Emergencias.RegistroSesiones
      ├── Emergencias.Bitacora                  (proceso con spawn_link + receive)
      ├── Task.Supervisor Emergencias.Tareas    (trabajo paralelo: coincidencias, resumen, simulación)
      ├── Emergencias.Servidores.Supervisor     (GenServers del dominio)
      ├── Emergencias.Sesiones.SupervisorSesiones (DynamicSupervisor, una sesión por usuario)
      ├── Phoenix.PubSub Emergencias.PubSub     (avisa a la web cada acción registrada)
      └── EmergenciasWeb.Endpoint               (interfaz web: un proceso LiveView por navegador)
  """

  use Application

  @impl true
  def start(_type, _args) do
    File.mkdir_p!(Emergencias.Persistencia.directorio())

    children = [
      {Registry, keys: :unique, name: Emergencias.RegistroSesiones},
      Emergencias.Bitacora,
      {Task.Supervisor, name: Emergencias.Tareas},
      Emergencias.Servidores.Supervisor,
      Emergencias.Sesiones.SupervisorSesiones,
      {Phoenix.PubSub, name: Emergencias.PubSub},
      # La web va al final: cuando acepta conexiones, todo lo demás ya está listo.
      EmergenciasWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Emergencias.Supervisor)
  end
end
