defmodule EmergenciasWeb.WebTest do
  @moduledoc """
  Pruebas de la interfaz web: acceso con reconocimiento del usuario, sesión por
  navegador, permisos por rol, acciones desde los formularios y actualización en
  vivo entre dos navegadores.
  """

  use Emergencias.CasoSistema, async: false

  import Plug.Conn, only: [get_session: 2]
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Emergencias.Servidores.{Usuarios, Zonas}

  @endpoint EmergenciasWeb.Endpoint

  defp usuario!(username, tipo) do
    {:ok, _, :registrado} =
      Usuarios.conectar(username, "0000", tipo, "centro", "Nombre #{username}")

    username
  end

  # Un "navegador" con la cookie de sesión ya iniciada para ese usuario.
  defp navegador(username),
    do: build_conn() |> init_test_session(%{usuario: username})

  defp esperar(condicion, intentos \\ 40) do
    cond do
      condicion.() -> true
      intentos == 0 -> false
      true -> Process.sleep(25) && esperar(condicion, intentos - 1)
    end
  end

  describe "acceso" do
    test "reconoce si el usuario está registrado y solo pide la contraseña" do
      usuario!("laura", "coordinador")
      {:ok, vista, html} = live(build_conn(), "/")
      assert html =~ "Gestión de Emergencias"

      html = render_change(vista, "cambiar", %{"acceso" => %{"usuario" => "Laura"}})
      assert html =~ "registrado. Ingrese su contraseña"
      refute html =~ "Tipo de usuario"

      html = render_change(vista, "cambiar", %{"acceso" => %{"usuario" => "nuevo"}})
      assert html =~ "no existe: se creará una cuenta nueva"
      assert html =~ "Tipo de usuario"
    end

    test "contraseña incorrecta muestra el error y no envía el formulario" do
      usuario!("laura", "coordinador")
      {:ok, vista, _html} = live(build_conn(), "/")

      html =
        render_submit(vista, "entrar", %{"acceso" => %{"usuario" => "laura", "clave" => "mala"}})

      assert html =~ "contraseña incorrecta"
      refute html =~ "phx-trigger-action"
    end

    test "un usuario nuevo se registra desde la web" do
      {:ok, vista, _html} = live(build_conn(), "/")

      render_submit(vista, "entrar", %{
        "acceso" => %{"usuario" => "ana", "clave" => "abcd", "tipo" => "voluntario"}
      })

      assert {:ok, %{tipo: :voluntario}} = Usuarios.obtener("ana")
    end

    test "el controlador guarda el usuario en la sesión y lleva al panel" do
      usuario!("laura", "coordinador")

      conn =
        post(build_conn(), "/entrar", %{"acceso" => %{"usuario" => "laura", "clave" => "0000"}})

      assert redirected_to(conn) == "/panel"
      assert get_session(conn, :usuario) == "laura"
    end

    test "sin sesión el panel redirige al acceso" do
      assert {:error, {:redirect, %{to: "/"}}} = live(build_conn(), "/panel")
    end
  end

  describe "panel" do
    test "cada navegador abre su sesión y al cerrarse la sesión termina" do
      usuario!("laura", "coordinador")
      {:ok, vista, html} = live(navegador("laura"), "/panel")

      assert html =~ "Resumen"
      assert "laura" in Emergencias.conectados()

      GenServer.stop(vista.pid)
      assert esperar(fn -> "laura" not in Emergencias.conectados() end)
    end

    test "el menú lateral y las acciones dependen del rol" do
      usuario!("pedro", "ciudadano")
      {:ok, _vista, html} = live(navegador("pedro"), "/panel/necesidades")

      assert html =~ "Registrar necesidad"
      refute html =~ "Despacho automático"
      refute html =~ "Cuenta y usuarios" and html =~ "Lista de usuarios"
    end

    test "un formulario de acción ejecuta el comando con las validaciones del sistema" do
      usuario!("laura", "coordinador")
      {:ok, vista, _html} = live(navegador("laura"), "/panel/zonas")

      # Opción "Registrar zona" (sección 0, opción 0 del menú).
      html =
        render_submit(vista, "accion", %{
          "seccion" => "0",
          "opcion" => "0",
          "c0" => "comuna_1",
          "c1" => "Comuna 1 - Centenario",
          "c2" => "alto",
          "c3" => "300"
        })

      assert html =~ "register_zone comuna_1"
      assert {:ok, _} = Zonas.obtener("comuna_1")

      # Repetir el código da el error de validación de siempre.
      html =
        render_submit(vista, "accion", %{
          "seccion" => "0",
          "opcion" => "0",
          "c0" => "comuna_1",
          "c1" => "Otra",
          "c2" => "bajo",
          "c3" => ""
        })

      assert html =~ "ya existe"
    end

    test "lo que hace un usuario aparece en vivo en el navegador de otro" do
      usuario!("laura", "coordinador")
      usuario!("pedro", "ciudadano")
      con_demo()

      {:ok, vista_laura, html} = live(navegador("laura"), "/panel/necesidades")
      refute html =~ "<code>N001</code>"

      {:ok, vista_pedro, _html} = live(navegador("pedro"), "/panel/necesidades")

      render_submit(vista_pedro, "accion", %{
        "seccion" => "1",
        "opcion" => "0",
        "c0" => "agua",
        "c1" => "30",
        "c2" => "critica",
        "c3" => "centro",
        "c4" => "Punto sector 3",
        "c5" => ""
      })

      assert esperar(fn -> render(vista_laura) =~ "<code>N001</code>" end)
    end

    test "la asignación desde la tabla respeta el inventario" do
      usuario!("laura", "coordinador")
      con_demo()
      recurso!("R001", "agua", 50)
      necesidad!("agua", 30, "critica")
      necesidad!("agua", 25, "alta")

      {:ok, vista, _html} = live(navegador("laura"), "/panel/necesidades")

      html =
        render_submit(vista, "asignar", %{
          "necesidad" => "N001",
          "tipo" => "agua",
          "cantidad" => "30"
        })

      assert html =~ "OK"

      html =
        render_submit(vista, "asignar", %{
          "necesidad" => "N002",
          "tipo" => "agua",
          "cantidad" => "25"
        })

      assert html =~ "inventario insuficiente"
    end

    test "una segunda pestaña del mismo usuario puede tomar la sesión" do
      usuario!("laura", "coordinador")
      {:ok, primera, _html} = live(navegador("laura"), "/panel")
      {:ok, segunda, html} = live(navegador("laura"), "/panel")

      assert html =~ "Sesión abierta en otro lugar"

      html = render_click(segunda, "usar_aqui")
      assert html =~ "Resumen"
      assert esperar(fn -> render(primera) =~ "La sesión se cerró" end)
    end

    test "cada rol solo consulta lo que puede: recorrer el panel no deja errores en la bitácora" do
      Emergencias.DatosIniciales.cargar()

      for {usuario, _tipo} <- Emergencias.DatosIniciales.usuarios() do
        {:ok, vista, _html} = live(navegador(usuario), "/panel")

        for seccion <- ~w(inicio zonas necesidades recursos personas mascotas albergues cuenta) do
          render_patch(vista, "/panel/#{seccion}")
        end

        GenServer.stop(vista.pid)
      end

      errores =
        for {_fecha, usuario, accion, _detalle, "error"} <-
              Emergencias.Bitacora.consultar(nil, 500),
            do: {usuario, accion}

      assert errores == []
    end

    test "la página de usuarios del administrador no entra en un ciclo de recargas" do
      usuario!("sofia", "administrador")
      usuario!("laura", "coordinador")
      {:ok, vista, html} = live(navegador("sofia"), "/panel/cuenta")
      assert html =~ "Usuarios registrados"

      # Una acción de otro usuario avisa a la página, que recarga una sola vez.
      {:ok, _} = Emergencias.registrar_zona(%{username: "laura", tipo: :coordinador}, "norte", "Norte", "alto")
      Process.sleep(300)
      render(vista)

      consultas =
        for {_fecha, "sofia", "list_users", _detalle, _resultado} <-
              Emergencias.Bitacora.consultar(nil, 500),
            do: :list_users

      assert consultas == []
    end

    test "la consola web ejecuta los mismos comandos" do
      usuario!("laura", "coordinador")
      {:ok, vista, _html} = live(navegador("laura"), "/panel/consola")
      html = render_submit(vista, "consola", %{"linea" => "whoami"})
      assert html =~ "laura"
    end
  end
end
