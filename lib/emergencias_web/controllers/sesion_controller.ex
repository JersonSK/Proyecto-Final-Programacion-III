defmodule EmergenciasWeb.SesionController do
  @moduledoc """
  Guarda o borra el usuario en la cookie de sesión. Una página LiveView no puede
  escribir cookies, por eso el formulario de acceso termina enviándose aquí.
  """

  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  alias Emergencias.CLI.Formato

  def crear(conn, %{"acceso" => %{"usuario" => usuario, "clave" => clave}}) do
    case Emergencias.autenticar(usuario, clave) do
      {:ok, cuenta, _modo} ->
        conn
        |> configure_session(renew: true)
        |> put_session(:usuario, cuenta.username)
        |> redirect(to: "/panel")

      {:error, motivo} ->
        conn
        |> put_flash(:error, Formato.mensaje_error(motivo))
        |> redirect(to: "/")
    end
  end

  def crear(conn, _params), do: redirect(conn, to: "/")

  def eliminar(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: "/")
  end
end
