defmodule EmergenciasWeb.PanelLive do
  @moduledoc """
  Panel principal de la interfaz web.

  Cada navegador conectado es un proceso LiveView en el nodo servidor. Al montar,
  ese proceso abre la `Sesion` del usuario (igual que una terminal) y la sesión lo
  monitorea: si se cierra la pestaña, la sesión termina sola.

  * Los datos se leen con las funciones de la fachada `Emergencias`, con el usuario
    conectado como actor, así que se aplican los mismos permisos que en la consola.
  * Las acciones se ejecutan como líneas de comando con `CLI.Comandos.ejecutar/2`:
    los formularios salen de las opciones de `CLI.Menu` y los botones de las tablas
    arman la línea equivalente (`attend_need N001`, `confirm_match PET001 PET002`...).
  * Cada acción registrada en la bitácora llega por PubSub a todos los navegadores,
    que recargan lo que muestran: lo que hace un usuario lo ven todos en vivo.
  """

  use Phoenix.LiveView

  import EmergenciasWeb.Componentes

  alias Emergencias.{Bitacora, Permisos}
  alias Emergencias.CLI.{Comandos, Menu}
  alias Emergencias.Dominio.Necesidad
  alias Emergencias.Sesiones.Sesion

  @secciones [
    %{id: "inicio", titulo: "Resumen", icono: "◉", menu: "Resumen y reportes"},
    %{id: "zonas", titulo: "Zonas", icono: "◈", menu: "Zonas y sectores"},
    %{id: "necesidades", titulo: "Necesidades", icono: "✚", menu: "Necesidades"},
    %{id: "recursos", titulo: "Recursos", icono: "▦", menu: "Recursos e inventario"},
    %{
      id: "personas",
      titulo: "Personas y mensajes",
      icono: "☺",
      menu: "Personas y mensajes familiares"
    },
    %{id: "mascotas", titulo: "Mascotas", icono: "❖", menu: "Mascotas perdidas y encontradas"},
    %{id: "albergues", titulo: "Albergues", icono: "⌂", menu: "Albergues"},
    %{id: "cuenta", titulo: "Cuenta y usuarios", icono: "⚙", menu: "Mi cuenta y usuarios"},
    %{id: "consola", titulo: "Consola de comandos", icono: "›", menu: nil}
  ]

  @intentos_sesion 10

  # ===========================================================================
  # Montaje y sesión
  # ===========================================================================

  @impl true
  def mount(_params, %{"usuario" => username}, socket) do
    socket =
      assign(socket,
        username: username,
        estado: :cargando,
        sesion: nil,
        ref_sesion: nil,
        usuario: nil,
        seccion: "inicio",
        datos: %{},
        filtros: %{},
        resultado: nil,
        asignando: nil,
        persona: nil,
        coincidencias: nil,
        historial_consola: [],
        conectados: [],
        lugares: []
      )

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Emergencias.PubSub, Bitacora.tema())
      {:ok, abrir_sesion(socket, false)}
    else
      {:ok, socket}
    end
  end

  def mount(_params, _session, socket), do: {:ok, redirect(socket, to: "/")}

  # Abre la sesión del usuario para este proceso. Al recargar la página la sesión
  # anterior puede tardar unos milisegundos en cerrarse: por eso se reintenta.
  defp abrir_sesion(socket, reemplazar?, intento \\ 1) do
    case Emergencias.abrir_sesion(socket.assigns.username, self(), reemplazar: reemplazar?) do
      {:ok, %{usuario: usuario, sesion: sesion}} ->
        socket
        |> assign(
          estado: :activa,
          sesion: sesion,
          ref_sesion: Process.monitor(sesion),
          usuario: usuario
        )
        |> cargar()

      {:error, :ya_conectado} when intento < @intentos_sesion ->
        Process.sleep(100)
        abrir_sesion(socket, reemplazar?, intento + 1)

      {:error, :ya_conectado} ->
        assign(socket, estado: :ocupada)

      {:error, _motivo} ->
        # El usuario ya no existe (por ejemplo, se borraron los datos).
        redirect(socket, to: "/salir")
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    seccion = params["seccion"] || "inicio"

    if Enum.any?(@secciones, &(&1.id == seccion)) do
      {:noreply,
       socket
       |> assign(
         seccion: seccion,
         page_title: titulo(seccion),
         resultado: nil,
         asignando: nil,
         coincidencias: nil
       )
       |> cargar()}
    else
      {:noreply, push_patch(socket, to: "/panel")}
    end
  end

  # ===========================================================================
  # Eventos
  # ===========================================================================

  @impl true
  def handle_event("accion", %{"seccion" => s, "opcion" => o} = params, socket) do
    {_nombre, opciones} = Enum.at(Menu.secciones(), String.to_integer(s))
    opcion = Enum.at(opciones, String.to_integer(o))

    valores =
      opcion.campos
      |> Enum.with_index()
      |> Enum.map(fn {campo, i} -> valor_campo(campo, params["c#{i}"]) end)

    {:noreply, ejecutar(socket, Menu.construir_linea(opcion.comando, valores))}
  end

  def handle_event("comando", %{"linea" => linea}, socket),
    do: {:noreply, ejecutar(socket, linea)}

  def handle_event("asignar", %{"necesidad" => id} = params, socket) do
    linea =
      Menu.construir_linea("assign_resource", [
        {:arg, id},
        {:arg, params["tipo"]},
        {:arg, params["cantidad"]},
        {:opcion, "desde", presente(params["desde"])}
      ])

    {:noreply, socket |> assign(asignando: nil) |> ejecutar(linea)}
  end

  def handle_event("abrir_asignar", %{"id" => id}, socket),
    do: {:noreply, assign(socket, asignando: id)}

  def handle_event("cerrar_asignar", _params, socket),
    do: {:noreply, assign(socket, asignando: nil)}

  def handle_event("filtrar", params, socket) do
    filtros =
      params
      |> Map.get("filtro", %{})
      |> Enum.reject(fn {_clave, valor} -> String.trim(valor) == "" end)
      |> Map.new(fn {clave, valor} -> {clave, String.trim(valor)} end)

    {:noreply, socket |> assign(filtros: filtros) |> cargar()}
  end

  def handle_event("ver_persona", %{"documento" => documento}, socket),
    do: {:noreply, socket |> assign(persona: documento) |> cargar()}

  def handle_event("cerrar_persona", _params, socket),
    do: {:noreply, socket |> assign(persona: nil) |> cargar()}

  def handle_event("enviar_mensaje", %{"destinatario" => destino, "contenido" => texto}, socket) do
    linea = Menu.construir_linea("send_family_message", [{:arg, destino}, {:arg, texto}])
    {:noreply, ejecutar(socket, linea)}
  end

  def handle_event("buscar_coincidencias", _params, socket) do
    case Emergencias.buscar_coincidencias(socket.assigns.usuario) do
      {:ok, lista} -> {:noreply, socket |> assign(coincidencias: lista) |> cargar()}
      {:error, motivo} -> {:noreply, mostrar(socket, "match_pets", error(motivo))}
    end
  end

  def handle_event("consola", %{"linea" => linea}, socket) do
    case String.trim(linea) do
      "" ->
        {:noreply, socket}

      linea ->
        {estado, salida} = Comandos.ejecutar(linea, %{sesion: socket.assigns.sesion})
        historial = Enum.take([{linea, salida} | socket.assigns.historial_consola], 30)

        socket =
          socket
          |> assign(historial_consola: historial)
          |> revisar_sesion(estado)

        {:noreply, cargar(socket)}
    end
  end

  def handle_event("limpiar_resultado", _params, socket),
    do: {:noreply, assign(socket, resultado: nil)}

  def handle_event("usar_aqui", _params, socket),
    do: {:noreply, abrir_sesion(socket, true)}

  def handle_event("desconectar", _params, socket) do
    if socket.assigns.sesion do
      Process.demonitor(socket.assigns.ref_sesion, [:flush])
      Emergencias.desconectar(socket.assigns.sesion)
    end

    {:noreply, redirect(socket, to: "/salir")}
  end

  # ===========================================================================
  # Mensajes
  # ===========================================================================

  # Solo una acción exitosa puede haber cambiado los datos. Ignorar los errores evita
  # además un ciclo: una consulta fallida se registra, se avisa y volvería a recargar.
  @impl true
  def handle_info(
        {:actividad, {_fecha, _usuario, _accion, _detalle, "ok"}},
        %{assigns: %{estado: :activa}} = socket
      ),
      do: {:noreply, cargar(socket)}

  def handle_info({:actividad, _entrada}, socket), do: {:noreply, socket}

  # La sesión terminó por fuera de esta página (otra pestaña o terminal la reemplazó).
  def handle_info({:DOWN, ref, :process, _pid, _motivo}, %{assigns: %{ref_sesion: ref}} = socket),
    do: {:noreply, assign(socket, estado: :cerrada, sesion: nil, ref_sesion: nil)}

  def handle_info(_mensaje, socket), do: {:noreply, socket}

  # ===========================================================================
  # Ejecución de comandos
  # ===========================================================================

  defp ejecutar(socket, linea) do
    {estado, salida} = Comandos.ejecutar(linea, %{sesion: socket.assigns.sesion})

    socket
    |> mostrar(linea, salida)
    |> revisar_sesion(estado)
    |> cargar()
  end

  defp revisar_sesion(socket, %{sesion: nil}),
    do: assign(socket, estado: :cerrada, sesion: nil)

  defp revisar_sesion(socket, _estado), do: socket

  defp mostrar(socket, linea, salida) do
    tipo =
      cond do
        String.starts_with?(salida, "ERROR") -> :error
        String.starts_with?(salida, "OK") -> :ok
        true -> :info
      end

    assign(socket, resultado: %{linea: linea, salida: salida, tipo: tipo})
  end

  defp error(motivo), do: Emergencias.CLI.Formato.error(motivo)

  defp valor_campo({:filtro, clave, campo}, texto) do
    {:arg, valor} = valor_campo(campo, texto)
    {:opcion, clave, valor}
  end

  defp valor_campo({:opcional, _etiqueta, defecto}, texto), do: {:arg, presente(texto) || defecto}
  defp valor_campo(_campo, texto), do: {:arg, presente(texto)}

  defp presente(nil), do: nil

  defp presente(texto) do
    case String.trim(texto) do
      "" -> nil
      valor -> valor
    end
  end

  # ===========================================================================
  # Carga de datos (siempre a través de la fachada, con el usuario como actor)
  # ===========================================================================

  defp cargar(%{assigns: %{estado: :activa}} = socket) do
    case usuario_vigente(socket.assigns.sesion) do
      nil ->
        assign(socket, estado: :cerrada, sesion: nil)

      usuario ->
        socket
        |> assign(
          usuario: usuario,
          conectados: Emergencias.conectados(),
          lugares: lugares()
        )
        |> assign(datos: datos(socket.assigns.seccion, usuario, socket.assigns))
    end
  end

  defp cargar(socket), do: socket

  # El usuario se relee de la sesión: si un administrador cambia su rol, se refleja.
  defp usuario_vigente(nil), do: nil

  defp usuario_vigente(sesion) do
    Sesion.usuario(sesion)
  catch
    :exit, _ -> nil
  end

  defp lugares do
    zonas =
      Emergencias.Servidores.Zonas.arbol()
      |> Emergencias.Dominio.Zona.aplanar()
      |> Enum.map(fn {_profundidad, nodo} -> {nodo.codigo, nodo.nombre} end)

    albergues = Enum.map(Emergencias.Servidores.Albergues.listar(), &{&1.codigo, &1.nombre})
    zonas ++ albergues
  end

  # Cada consulta se hace solo si el rol la permite: así no se llena la bitácora de
  # intentos rechazados y cada rol ve exactamente lo que le corresponde.
  defp datos("inicio", u, _assigns) do
    %{
      resumen: si_puede(u, :summary, fn -> Emergencias.resumen(u) end),
      criticos: si_puede(u, :critical_resources, fn -> Emergencias.recursos_criticos(u) end),
      actividad: actividad_visible(u)
    }
  end

  defp datos("zonas", u, _assigns) do
    arbol = valor(Emergencias.listar_zonas(u)) || []

    # Estadísticas acumuladas (recursivas) de cada zona raíz, si el rol puede verlas.
    estadisticas =
      if Permisos.permitido?(u.tipo, :zone_stats) do
        for {0, nodo} <- arbol,
            {:ok, stats} <- [Emergencias.estadisticas_zona(u, nodo.codigo)],
            do: stats
      else
        []
      end

    %{arbol: arbol, estadisticas: estadisticas}
  end

  defp datos("necesidades", u, %{filtros: filtros}) do
    case Emergencias.listar_necesidades(u, filtros) do
      {:ok, lista} -> %{necesidades: lista, error: nil}
      {:error, motivo} -> %{necesidades: [], error: Emergencias.CLI.Formato.mensaje_error(motivo)}
    end
  end

  defp datos("recursos", u, %{filtros: filtros}) do
    # Un ciudadano no ve el inventario completo, solo consulta disponibilidad.
    {recursos, error} =
      if Permisos.permitido?(u.tipo, :list_resources) do
        case Emergencias.listar_recursos(u, filtros) do
          {:ok, lista} -> {lista, nil}
          {:error, motivo} -> {[], Emergencias.CLI.Formato.mensaje_error(motivo)}
        end
      else
        {nil, nil}
      end

    %{
      recursos: recursos,
      error: error,
      criticos: si_puede(u, :critical_resources, fn -> Emergencias.recursos_criticos(u) end),
      umbral: Application.get_env(:emergencias, :umbral_critico, 10)
    }
  end

  defp datos("personas", u, %{filtros: filtros, persona: documento}) do
    personas =
      case Emergencias.buscar_personas(u, filtros) do
        {:ok, lista} -> lista
        _ -> []
      end

    %{personas: personas, detalle: detalle_persona(u, documento)}
  end

  defp datos("mascotas", u, %{filtros: filtros}) do
    mascotas =
      case Emergencias.listar_mascotas(u, filtros) do
        {:ok, lista} -> lista
        _ -> []
      end

    %{
      perdidas: Enum.filter(mascotas, &(&1.tipo_reporte == :perdida)),
      encontradas: Enum.filter(mascotas, &(&1.tipo_reporte == :encontrada))
    }
  end

  # Un ciudadano solo puede ver los albergues que tienen cupo.
  defp datos("albergues", u, _assigns) do
    albergues =
      si_puede(u, :list_shelters, fn -> Emergencias.listar_albergues(u) end) ||
        valor(Emergencias.albergues_disponibles(u)) || []

    %{albergues: albergues}
  end

  defp datos("cuenta", u, _assigns) do
    %{
      usuarios: si_puede(u, :list_users, fn -> Emergencias.listar_usuarios(u) end),
      actividad: Enum.take(valor(Emergencias.actividad(u)) || [], 15)
    }
  end

  defp datos("consola", _u, _assigns), do: %{}

  defp detalle_persona(_u, nil), do: nil

  defp detalle_persona(u, documento) do
    with {:ok, persona} <- Emergencias.buscar_persona(u, documento) do
      propios = valor(Emergencias.mensajes_familia(u, documento)) || []

      familiares =
        if persona.familia,
          do: valor(Emergencias.mensajes_familia(u, "familia:#{persona.familia}")) || [],
          else: []

      %{
        persona: persona,
        mensajes: Enum.sort_by(propios ++ familiares, & &1.fecha, {:desc, NaiveDateTime})
      }
    else
      _ -> nil
    end
  end

  # Ver la actividad de otros usuarios es solo para administradores.
  defp actividad_visible(u) do
    if Permisos.permitido?(u.tipo, :activity_all),
      do: Bitacora.consultar(nil, 12),
      else: Bitacora.consultar(u.username, 12)
  end

  defp valor({:ok, valor}), do: valor
  defp valor(_error), do: nil

  defp si_puede(usuario, accion, consulta) do
    if Permisos.permitido?(usuario.tipo, accion), do: valor(consulta.()), else: nil
  end

  # ===========================================================================
  # Utilidades para la vista
  # ===========================================================================

  defp titulo(id), do: Enum.find(@secciones, &(&1.id == id)).titulo

  defp secciones_visibles(usuario) do
    Enum.filter(@secciones, fn seccion ->
      seccion.menu == nil or seccion.id == "inicio" or acciones(seccion.menu, usuario) != []
    end)
  end

  # Opciones del menú que el rol puede usar, con su posición original (para el formulario).
  defp acciones(nil, _usuario), do: []

  defp acciones(nombre_menu, usuario) do
    secciones = Menu.secciones()
    indice = Enum.find_index(secciones, fn {nombre, _} -> nombre == nombre_menu end)
    {_nombre, opciones} = Enum.at(secciones, indice)

    permitidas = MapSet.new(Menu.permitidas(opciones, usuario))

    opciones
    |> Enum.with_index()
    |> Enum.filter(fn {opcion, _i} -> MapSet.member?(permitidas, opcion) end)
    |> Enum.map(fn {opcion, i} -> {indice, i, opcion} end)
  end

  defp puede?(usuario, comando), do: Permisos.permitido?(usuario.tipo, Comandos.permiso(comando))

  defp seccion_actual(id), do: Enum.find(@secciones, &(&1.id == id))

  # ===========================================================================
  # Vista
  # ===========================================================================

  @impl true
  def render(%{estado: :cargando} = assigns) do
    ~H"""
    <main class="centrado">
      <p class="tenue">Conectando con el servidor…</p>
    </main>
    """
  end

  def render(%{estado: estado} = assigns) when estado in [:ocupada, :cerrada] do
    ~H"""
    <main class="centrado">
      <section class="acceso-tarjeta">
        <h1 :if={@estado == :ocupada}>Sesión abierta en otro lugar</h1>
        <h1 :if={@estado == :cerrada}>La sesión se cerró</h1>
        <p :if={@estado == :ocupada}>
          El usuario <strong>{@username}</strong>
          ya tiene una sesión abierta en otra pestaña o en una terminal.
          Cada usuario puede tener una sola sesión a la vez.
        </p>
        <p :if={@estado == :cerrada}>
          La sesión de <strong>{@username}</strong>
          se cerró, probablemente porque se abrió en otra pestaña o terminal.
        </p>
        <div class="fila-botones">
          <button phx-click="usar_aqui" class="boton boton-primario">
            Cerrar la otra sesión y continuar aquí
          </button>
          <a href="/salir" class="boton">Salir</a>
        </div>
      </section>
    </main>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="app">
      <aside class="lateral">
        <div class="marca">
          <span class="marca-icono" aria-hidden="true">✚</span>
          <div>
            <strong>Emergencias</strong>
            <span class="tenue">Programación III</span>
          </div>
        </div>
        <nav class="navegacion" aria-label="Secciones">
          <.link
            :for={s <- secciones_visibles(@usuario)}
            patch={"/panel/#{s.id}"}
            class={["nav-enlace", s.id == @seccion && "activo"]}
          >
            <span class="nav-icono" aria-hidden="true">{s.icono}</span>
            {s.titulo}
          </.link>
        </nav>
        <div class="cuenta">
          <div>
            <strong>{@usuario.nombre_completo || @usuario.username}</strong>
            <span class="tenue">
              {@usuario.username} · {texto(@usuario.tipo)}{if @usuario.zona,
                do: " · #{@usuario.zona}"}
            </span>
          </div>
          <button phx-click="desconectar" class="boton boton-pequeno">Desconectarse</button>
        </div>
      </aside>

      <main class="contenido">
        <header class="encabezado">
          <h1>{titulo(@seccion)}</h1>
          <div class="estado-vivo" title={Enum.join(@conectados, ", ")}>
            <span class="punto-vivo" aria-hidden="true"></span>
            En vivo · {length(@conectados)} {if length(@conectados) == 1,
              do: "usuario conectado",
              else: "usuarios conectados"}
          </div>
        </header>

        <div :if={@resultado} class={"resultado resultado-#{@resultado.tipo}"} role="status">
          <div class="resultado-cabecera">
            <code>&gt; {@resultado.linea}</code>
            <button phx-click="limpiar_resultado" class="boton-icono" aria-label="Cerrar">×</button>
          </div>
          <pre>{@resultado.salida}</pre>
        </div>

        <.lista_lugares lugares={@lugares} />

        {vista(assigns)}

        <section
          :if={acciones(seccion_actual(@seccion).menu, @usuario) != []}
          class="panel acciones"
        >
          <header class="panel-cabecera">
            <h2>Acciones</h2>
            <span class="tenue">Solo se muestran las que permite su rol</span>
          </header>
          <.formulario_accion
            :for={{s, i, opcion} <- acciones(seccion_actual(@seccion).menu, @usuario)}
            opcion={opcion}
            seccion={s}
            indice={i}
          />
        </section>
      </main>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Resumen
  # ---------------------------------------------------------------------------

  defp vista(%{seccion: "inicio", datos: %{resumen: nil}} = assigns) do
    ~H"""
    <.panel titulo={"Hola, #{@usuario.nombre_completo || @usuario.username}"}>
      <p>
        Está conectado como <strong>{texto(@usuario.tipo)}</strong>. Use el menú de la izquierda para
        reportar personas, mascotas o necesidades, consultar albergues y enviar mensajes a familiares.
      </p>
    </.panel>
    <.panel titulo="Mi actividad reciente">
      <.tabla_actividad entradas={@datos.actividad} />
    </.panel>
    """
  end

  defp vista(%{seccion: "inicio"} = assigns) do
    r = assigns.datos.resumen
    abiertas = r.pendientes_por_prioridad |> Map.values() |> Enum.sum()

    assigns =
      assign(assigns,
        r: r,
        abiertas: abiertas,
        criticas: Map.get(r.pendientes_por_prioridad, :critica, 0),
        personas: r.personas_por_estado |> Map.values() |> Enum.sum(),
        mascotas_abiertas:
          r.mascotas_por_estado |> Map.drop([:resuelta]) |> Map.values() |> Enum.sum()
      )

    ~H"""
    <div class="indicadores">
      <.indicador
        titulo="Necesidades abiertas"
        valor={@abiertas}
        detalle={"#{@criticas} críticas"}
        tono={if @criticas > 0, do: "rojo", else: "neutro"}
      />
      <.indicador
        titulo="Personas localizadas"
        valor={"#{@r.personas_localizadas} / #{@personas}"}
        detalle="del total reportado"
      />
      <.indicador
        titulo="Ocupación de albergues"
        valor={"#{porcentaje(@r.ocupacion_total, @r.capacidad_total)}%"}
        detalle={"#{@r.ocupacion_total} de #{@r.capacidad_total} cupos · #{@r.albergues} albergues"}
        tono={
          if porcentaje(@r.ocupacion_total, @r.capacidad_total) >= 80, do: "ambar", else: "neutro"
        }
      />
      <.indicador
        titulo="Mensajes pendientes"
        valor={@r.mensajes_pendientes}
        detalle={"de #{@r.mensajes_total} mensajes"}
      />
      <.indicador
        titulo="Mascotas sin resolver"
        valor={@mascotas_abiertas}
        detalle={"#{Map.get(@r.mascotas_por_tipo, :perdida, 0)} perdidas · #{Map.get(@r.mascotas_por_tipo, :encontrada, 0)} encontradas"}
      />
      <.indicador titulo="Zonas registradas" valor={@r.zonas} detalle="comunas y corregimientos" />
    </div>

    <div class="rejilla-2">
      <.panel titulo="Necesidades pendientes (por prioridad)">
        <.vacio :if={@r.necesidades_pendientes == []} mensaje="No hay necesidades abiertas." />
        <table :if={@r.necesidades_pendientes != []} class="tabla">
          <thead>
            <tr>
              <th>ID</th>
              <th>Tipo</th>
              <th>Prioridad</th>
              <th>Zona</th>
              <th>Faltan</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={n <- Enum.take(@r.necesidades_pendientes, 8)}>
              <td><code>{n.id}</code></td>
              <td>{texto(n.tipo)}</td>
              <td><.insignia valor={n.prioridad} /></td>
              <td>{n.zona}</td>
              <td class="sin-corte">{Necesidad.faltante(n)} de {n.cantidad}</td>
            </tr>
          </tbody>
        </table>
        <:acciones>
          <.link patch="/panel/necesidades" class="enlace">Ver todas →</.link>
        </:acciones>
      </.panel>

      <.panel titulo="Inventario por tipo">
        <.vacio :if={@r.recursos_por_tipo == []} mensaje="No hay recursos registrados." />
        <ul class="lista-simple">
          <li :for={{nombre, total, unidad} <- @r.recursos_por_tipo}>
            <span>{texto(nombre)}</span>
            <strong>{total} {unidad}</strong>
          </li>
        </ul>
      </.panel>

      <.panel :if={@datos.criticos} titulo="Recursos críticos">
        <.vacio
          :if={@datos.criticos.por_demanda == [] and @datos.criticos.por_umbral == []}
          mensaje="Ningún recurso en estado crítico."
        />
        <ul class="lista-simple">
          <li :for={c <- @datos.criticos.por_demanda}>
            <span>{texto(c.tipo)}: la demanda supera la existencia</span>
            <strong class="texto-rojo">{c.disponible} / {c.demanda}</strong>
          </li>
          <li :for={c <- @datos.criticos.por_umbral}>
            <span>{c.recurso.codigo} {texto(c.recurso.nombre)} en {c.recurso.ubicacion}</span>
            <strong class="texto-ambar">{c.recurso.cantidad} {c.recurso.unidad}</strong>
          </li>
        </ul>
      </.panel>

      <.panel titulo={
        if Permisos.permitido?(@usuario.tipo, :activity_all),
          do: "Actividad en vivo (todos los usuarios)",
          else: "Mi actividad reciente"
      }>
        <.tabla_actividad entradas={@datos.actividad} />
      </.panel>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Zonas
  # ---------------------------------------------------------------------------

  defp vista(%{seccion: "zonas"} = assigns) do
    ~H"""
    <div :if={@datos.estadisticas != []} class="indicadores indicadores-zonas">
      <div :for={z <- @datos.estadisticas} class="indicador">
        <span class="indicador-titulo">{z.nombre}</span>
        <strong class="indicador-valor">{z.totales.personas_afectadas}</strong>
        <span class="indicador-detalle">personas afectadas (zona + sectores)</span>
        <span class="indicador-detalle">
          <.insignia valor={z.nivel} /> {z.totales.necesidades_abiertas} necesidades abiertas · {z.totales.albergues} albergues · {z.totales.recursos} recursos
        </span>
      </div>
    </div>

    <.panel titulo="Árbol zona → sector → punto de atención">
      <.vacio :if={@datos.arbol == []} mensaje="No hay zonas registradas." />
      <table :if={@datos.arbol != []} class="tabla">
        <thead>
          <tr>
            <th>Código</th>
            <th>Nombre</th>
            <th>Tipo</th>
            <th>Nivel</th>
            <th class="num">Personas</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={{profundidad, nodo} <- @datos.arbol} class={"nivel-arbol-#{profundidad}"}>
            <td style={"padding-left: #{0.75 + profundidad * 1.5}rem"}>
              <span :if={profundidad > 0} class="tenue">└ </span><code>{nodo.codigo}</code>
            </td>
            <td>{nodo.nombre}</td>
            <td>{texto(nodo.tipo)}{if nodo.categoria, do: " (#{texto(nodo.categoria)})"}</td>
            <td><.insignia :if={nodo.nivel} valor={nodo.nivel} /></td>
            <td class="num">{nodo.personas}</td>
          </tr>
        </tbody>
      </table>
    </.panel>
    """
  end

  # ---------------------------------------------------------------------------
  # Necesidades
  # ---------------------------------------------------------------------------

  defp vista(%{seccion: "necesidades"} = assigns) do
    ~H"""
    <.panel titulo="Necesidades (ordenadas por prioridad)">
      <form id={"filtros-#{@seccion}"} phx-change="filtrar" class="filtros">
        <input
          type="text"
          name="filtro[zona]"
          placeholder="Zona o sector"
          list="lugares"
          value={@filtros["zona"]}
          phx-debounce="400"
        />
        <.selector
          nombre="filtro[tipo]"
          valor={@filtros["tipo"]}
          vacio="Todos los tipos"
          opciones={~w(agua alimentos medicamentos primeros_auxilios refugio transporte rescate otra)}
        />
        <.selector
          nombre="filtro[prioridad]"
          valor={@filtros["prioridad"]}
          vacio="Todas las prioridades"
          opciones={~w(critica alta media baja)}
        />
        <.selector
          nombre="filtro[estado]"
          valor={@filtros["estado"]}
          vacio="Todos los estados"
          opciones={~w(pendiente asignada en_atencion atendida cancelada)}
        />
      </form>
      <p :if={@datos.error} class="aviso aviso-error">{@datos.error}</p>
      <.vacio :if={@datos.necesidades == []} />
      <div :if={@datos.necesidades != []} class="tabla-contenedor">
        <table class="tabla">
          <thead>
            <tr>
              <th>ID</th>
              <th>Tipo</th>
              <th>Prioridad</th>
              <th>Zona</th>
              <th>Asignado</th>
              <th>Estado</th>
              <th>Descripción</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <%= for n <- @datos.necesidades do %>
              <tr>
                <td><code>{n.id}</code></td>
                <td>{texto(n.tipo)}</td>
                <td><.insignia valor={n.prioridad} /></td>
                <td>{n.zona}</td>
                <td class="celda-barra">
                  <span>{n.asignada} / {n.cantidad}</span>
                  <.barra valor={n.asignada} maximo={n.cantidad} />
                </td>
                <td><.insignia valor={n.estado} /></td>
                <td>
                  {n.descripcion}
                  <span :if={n.asociado_tipo != :zona} class="tenue">
                    ({texto(n.asociado_tipo)}: {n.asociado_ref})
                  </span>
                </td>
                <td class="celda-botones">
                  <button
                    :if={
                      puede?(@usuario, "assign_resource") and n.estado in [:pendiente, :asignada] and
                        Necesidad.faltante(n) > 0
                    }
                    phx-click="abrir_asignar"
                    phx-value-id={n.id}
                    class="boton boton-pequeno boton-primario"
                  >
                    Asignar
                  </button>
                  <button
                    :if={puede?(@usuario, "attend_need") and n.estado in [:pendiente, :asignada]}
                    phx-click="comando"
                    phx-value-linea={"attend_need #{n.id}"}
                    class="boton boton-pequeno"
                  >
                    Atender
                  </button>
                  <button
                    :if={puede?(@usuario, "close_need") and n.estado == :en_atencion}
                    phx-click="comando"
                    phx-value-linea={"close_need #{n.id}"}
                    class="boton boton-pequeno"
                  >
                    Cerrar
                  </button>
                  <button
                    :if={puede?(@usuario, "cancel_need") and Necesidad.abierta?(n)}
                    phx-click="comando"
                    phx-value-linea={"cancel_need #{n.id}"}
                    data-confirm={"¿Cancelar la necesidad #{n.id}?"}
                    class="boton boton-pequeno boton-peligro"
                  >
                    Cancelar
                  </button>
                </td>
              </tr>
              <tr :if={@asignando == n.id} class="fila-formulario">
                <td colspan="8">
                  <form phx-submit="asignar" class="formulario-linea">
                    <input type="hidden" name="necesidad" value={n.id} />
                    <label>
                      Tipo de recurso <input type="text" name="tipo" value={n.tipo} required />
                    </label>
                    <label>
                      Cantidad
                      <input
                        type="number"
                        name="cantidad"
                        min="1"
                        max={Necesidad.faltante(n)}
                        value={Necesidad.faltante(n)}
                        required
                      />
                    </label>
                    <label>
                      Desde el recurso <span class="tenue">(opcional)</span>
                      <input type="text" name="desde" placeholder="R001" />
                    </label>
                    <button type="submit" class="boton boton-primario">Asignar a {n.id}</button>
                    <button type="button" phx-click="cerrar_asignar" class="boton">Cancelar</button>
                  </form>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </.panel>
    """
  end

  # ---------------------------------------------------------------------------
  # Recursos
  # ---------------------------------------------------------------------------

  defp vista(%{seccion: "recursos"} = assigns) do
    ~H"""
    <.panel :if={@datos.recursos} titulo="Inventario">
      <form id={"filtros-#{@seccion}"} phx-change="filtrar" class="filtros">
        <input
          type="text"
          name="filtro[tipo]"
          placeholder="Tipo o categoría (ej: agua)"
          value={@filtros["tipo"]}
          phx-debounce="400"
        />
        <input
          type="text"
          name="filtro[zona]"
          placeholder="Zona"
          list="lugares"
          value={@filtros["zona"]}
          phx-debounce="400"
        />
      </form>
      <p :if={@datos.error} class="aviso aviso-error">{@datos.error}</p>
      <.vacio :if={@datos.recursos == []} />
      <div :if={@datos.recursos != []} class="tabla-contenedor">
        <table class="tabla">
          <thead>
            <tr>
              <th>Código</th>
              <th>Nombre</th>
              <th>Categoría</th>
              <th class="num">Cantidad</th>
              <th>Ubicación</th>
              <th>Zona</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={r <- @datos.recursos} class={r.cantidad <= @datos.umbral && "fila-alerta"}>
              <td><code>{r.codigo}</code></td>
              <td>{texto(r.nombre)}</td>
              <td>{texto(r.categoria)}</td>
              <td class="num"><strong>{r.cantidad}</strong> {r.unidad}</td>
              <td>{r.ubicacion}</td>
              <td>{r.zona}</td>
              <td class="celda-botones">
                <button
                  :if={puede?(@usuario, "resource_history")}
                  phx-click="comando"
                  phx-value-linea={"resource_history #{r.codigo}"}
                  class="boton boton-pequeno"
                >
                  Historial
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </.panel>
    <.panel :if={!@datos.recursos} titulo="Disponibilidad">
      <p>Su rol puede consultar la disponibilidad por tipo y zona en las acciones de abajo.</p>
    </.panel>
    """
  end

  # ---------------------------------------------------------------------------
  # Personas y mensajes
  # ---------------------------------------------------------------------------

  defp vista(%{seccion: "personas"} = assigns) do
    ~H"""
    <div class={["rejilla-2", !@datos.detalle && "rejilla-1"]}>
      <.panel titulo="Personas afectadas">
        <form id={"filtros-#{@seccion}"} phx-change="filtrar" class="filtros">
          <input
            type="text"
            name="filtro[nombre]"
            placeholder="Nombre"
            value={@filtros["nombre"]}
            phx-debounce="400"
          />
          <input
            type="text"
            name="filtro[documento]"
            placeholder="Documento"
            value={@filtros["documento"]}
            phx-debounce="400"
          />
          <input
            type="text"
            name="filtro[zona]"
            placeholder="Zona"
            list="lugares"
            value={@filtros["zona"]}
            phx-debounce="400"
          />
          <.selector
            nombre="filtro[estado]"
            valor={@filtros["estado"]}
            vacio="Todos los estados"
            opciones={~w(sin_informacion reportada localizada trasladada en_albergue reunificada)}
          />
        </form>
        <.vacio :if={@datos.personas == []} />
        <div :if={@datos.personas != []} class="tabla-contenedor">
          <table class="tabla">
            <thead>
              <tr>
                <th>Documento</th>
                <th>Nombre</th>
                <th>Edad</th>
                <th>Zona</th>
                <th>Estado</th>
                <th>Familia</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={p <- @datos.personas}
                class={
                  @datos.detalle && @datos.detalle.persona.documento == p.documento && "fila-activa"
                }
              >
                <td><code>{p.documento}</code></td>
                <td>{p.nombre}</td>
                <td>{p.edad || "—"}</td>
                <td>{p.zona}</td>
                <td><.insignia valor={p.estado} /></td>
                <td>{p.familia || "—"}</td>
                <td>
                  <button
                    phx-click="ver_persona"
                    phx-value-documento={p.documento}
                    class="boton boton-pequeno"
                  >
                    Ver
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.panel>

      <.panel :if={@datos.detalle} titulo={@datos.detalle.persona.nombre}>
        <:acciones>
          <button phx-click="cerrar_persona" class="boton-icono" aria-label="Cerrar">×</button>
        </:acciones>
        <p>
          <.insignia valor={@datos.detalle.persona.estado} />
          <span class="tenue">
            Documento {@datos.detalle.persona.documento} · zona {@datos.detalle.persona.zona}{if @datos.detalle.persona.familia,
              do: " · familia #{@datos.detalle.persona.familia}"}
          </span>
        </p>

        <h3>Historial de estados</h3>
        <ol class="linea-tiempo">
          <li :for={{fecha, desde, hacia, usuario, detalle} <- @datos.detalle.persona.historial}>
            <span class="tenue">{fecha(fecha)}</span>
            {if desde, do: "#{texto(desde)} → ", else: ""}<strong>{texto(hacia)}</strong>
            <span class="tenue">· {usuario}{if detalle not in [nil, ""], do: " · #{detalle}"}</span>
          </li>
        </ol>

        <h3>Mensajes</h3>
        <.vacio :if={@datos.detalle.mensajes == []} mensaje="Sin mensajes." />
        <ul class="mensajes">
          <li :for={m <- @datos.detalle.mensajes}>
            <div class="mensaje-cabecera">
              <span><code>{m.id}</code> de <strong>{m.remitente}</strong> para {m.destinatario}</span>
              <.insignia valor={m.estado} />
            </div>
            <p>{m.contenido}</p>
            <div class="mensaje-pie">
              <span class="tenue">{fecha(m.fecha)}</span>
              <button
                :if={puede?(@usuario, "mark_message") and m.estado == :pendiente}
                phx-click="comando"
                phx-value-linea={"mark_message #{m.id} entregado"}
                class="boton boton-pequeno"
              >
                Marcar entregado
              </button>
            </div>
          </li>
        </ul>

        <form
          :if={puede?(@usuario, "send_family_message")}
          phx-submit="enviar_mensaje"
          class="formulario"
        >
          <input type="hidden" name="destinatario" value={@datos.detalle.persona.documento} />
          <label>
            Dejar un mensaje para {@datos.detalle.persona.nombre}
            <textarea name="contenido" rows="2" required></textarea>
          </label>
          <button type="submit" class="boton boton-primario">Enviar mensaje</button>
        </form>
      </.panel>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Mascotas
  # ---------------------------------------------------------------------------

  defp vista(%{seccion: "mascotas"} = assigns) do
    ~H"""
    <.panel titulo="Reportes de mascotas">
      <:acciones>
        <button
          :if={puede?(@usuario, "match_pets")}
          phx-click="buscar_coincidencias"
          class="boton boton-primario"
        >
          Buscar coincidencias
        </button>
      </:acciones>
      <form id={"filtros-#{@seccion}"} phx-change="filtrar" class="filtros">
        <input
          type="text"
          name="filtro[especie]"
          placeholder="Especie"
          value={@filtros["especie"]}
          phx-debounce="400"
        />
        <input
          type="text"
          name="filtro[zona]"
          placeholder="Zona"
          list="lugares"
          value={@filtros["zona"]}
          phx-debounce="400"
        />
        <.selector
          nombre="filtro[estado]"
          valor={@filtros["estado"]}
          vacio="Todos los estados"
          opciones={~w(activa posible_coincidencia resuelta)}
        />
      </form>
      <div class="rejilla-2">
        <div>
          <h3>Perdidas ({length(@datos.perdidas)})</h3>
          <.vacio :if={@datos.perdidas == []} />
          <.tarjeta_mascota :for={m <- @datos.perdidas} mascota={m} />
        </div>
        <div>
          <h3>Encontradas ({length(@datos.encontradas)})</h3>
          <.vacio :if={@datos.encontradas == []} />
          <.tarjeta_mascota :for={m <- @datos.encontradas} mascota={m} />
        </div>
      </div>
    </.panel>

    <.panel :if={@coincidencias} titulo="Posibles coincidencias">
      <.vacio
        :if={@coincidencias == []}
        mensaje="No se encontraron coincidencias con puntaje suficiente (60 o más)."
      />
      <div :for={c <- @coincidencias} class="coincidencia">
        <div class="coincidencia-cabecera">
          <span><code>{c.perdida}</code> ↔ <code>{c.encontrada}</code></span>
          <strong>{c.puntaje} / 100</strong>
        </div>
        <.barra valor={c.puntaje} maximo={100} />
        <p class="tenue">
          {c.detalle |> Enum.sort() |> Enum.map_join(" · ", fn {k, v} -> "#{texto(k)} #{v}" end)}
        </p>
        <button
          :if={puede?(@usuario, "confirm_match")}
          phx-click="comando"
          phx-value-linea={"confirm_match #{c.perdida} #{c.encontrada}"}
          class="boton boton-pequeno boton-primario"
        >
          Confirmar y cerrar ambos reportes
        </button>
      </div>
    </.panel>
    """
  end

  # ---------------------------------------------------------------------------
  # Albergues
  # ---------------------------------------------------------------------------

  defp vista(%{seccion: "albergues"} = assigns) do
    ~H"""
    <.vacio :if={@datos.albergues == []} mensaje="No hay albergues para mostrar." />
    <div class="tarjetas">
      <article :for={a <- @datos.albergues} class="tarjeta">
        <header>
          <strong>{a.nombre}</strong>
          <code>{a.codigo}</code>
        </header>
        <p class="tenue">Zona {a.zona}</p>
        <.barra valor={a.ocupacion} maximo={a.capacidad} />
        <p>
          <strong>{a.ocupacion}</strong>
          de {a.capacidad} ({porcentaje(a.ocupacion, a.capacidad)}%) ·
          <span class={a.capacidad - a.ocupacion == 0 && "texto-rojo"}>
            {a.capacidad - a.ocupacion} cupos
          </span>
        </p>
        <button
          :if={puede?(@usuario, "check_shelter")}
          phx-click="comando"
          phx-value-linea={"check_shelter #{a.codigo}"}
          class="boton boton-pequeno"
        >
          Ver detalle
        </button>
      </article>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Cuenta y usuarios
  # ---------------------------------------------------------------------------

  defp vista(%{seccion: "cuenta"} = assigns) do
    ~H"""
    <div class="rejilla-2">
      <.panel titulo="Mi cuenta">
        <dl class="datos">
          <dt>Usuario</dt>
          <dd>{@usuario.username}</dd>
          <dt>Nombre</dt>
          <dd>{@usuario.nombre_completo || "—"}</dd>
          <dt>Tipo</dt>
          <dd>{texto(@usuario.tipo)}</dd>
          <dt>Zona principal</dt>
          <dd>{@usuario.zona || "—"}</dd>
        </dl>
        <h3>Usuarios conectados ahora</h3>
        <ul class="lista-chips">
          <li :for={u <- @conectados} class="chip">{u}</li>
        </ul>
      </.panel>

      <.panel :if={@datos.usuarios} titulo="Usuarios registrados">
        <table class="tabla">
          <thead>
            <tr>
              <th>Usuario</th>
              <th>Nombre</th>
              <th>Tipo</th>
              <th>Conectado</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{u, conectado} <- @datos.usuarios}>
              <td><code>{u.username}</code></td>
              <td>{u.nombre_completo || "—"}</td>
              <td>{texto(u.tipo)}</td>
              <td>
                <span :if={conectado} class="punto-vivo" title="conectado"></span>
              </td>
            </tr>
          </tbody>
        </table>
      </.panel>
    </div>

    <.panel titulo="Mi actividad">
      <.tabla_actividad entradas={@datos.actividad} />
    </.panel>
    """
  end

  # ---------------------------------------------------------------------------
  # Consola de comandos
  # ---------------------------------------------------------------------------

  defp vista(%{seccion: "consola"} = assigns) do
    ~H"""
    <.panel titulo="Consola">
      <p class="tenue">
        Los mismos comandos de la terminal (escriba <code>help</code>). Ejemplo:
        <code>list_needs prioridad=critica</code>
      </p>
      <form phx-submit="consola" class="consola-entrada">
        <span aria-hidden="true">&gt;</span>
        <input type="text" name="linea" autocomplete="off" autofocus placeholder="comando" />
        <button type="submit" class="boton boton-primario">Ejecutar</button>
      </form>
      <div class="consola">
        <div :for={{linea, salida} <- @historial_consola} class="consola-bloque">
          <code class="consola-linea">&gt; {linea}</code>
          <pre>{salida}</pre>
        </div>
      </div>
    </.panel>
    """
  end

  # ---------------------------------------------------------------------------
  # Componentes propios del panel
  # ---------------------------------------------------------------------------

  attr :nombre, :string, required: true
  attr :valor, :string, default: nil
  attr :vacio, :string, required: true
  attr :opciones, :list, required: true

  defp selector(assigns) do
    ~H"""
    <select name={@nombre}>
      <option value="">{@vacio}</option>
      <option :for={o <- @opciones} value={o} selected={@valor == o}>{texto(o)}</option>
    </select>
    """
  end

  attr :mascota, :map, required: true

  defp tarjeta_mascota(assigns) do
    ~H"""
    <article class="tarjeta tarjeta-mascota">
      <header>
        <strong>{@mascota.nombre || "Sin nombre"}</strong>
        <code>{@mascota.id}</code>
      </header>
      <p>
        {texto(@mascota.especie)} · {@mascota.color} · {texto(@mascota.tamano)}
        <span class="tenue">· zona {@mascota.zona}</span>
      </p>
      <p :if={@mascota.caracteristicas != ""} class="tenue">{@mascota.caracteristicas}</p>
      <p>
        <.insignia valor={@mascota.estado} />
        <span :if={@mascota.coincidencia_con} class="tenue">con {@mascota.coincidencia_con}</span>
        <span class="tenue">· contacto {@mascota.contacto}</span>
      </p>
    </article>
    """
  end

  attr :entradas, :list, required: true

  defp tabla_actividad(assigns) do
    ~H"""
    <.vacio :if={@entradas == []} mensaje="Sin actividad registrada." />
    <ul :if={@entradas != []} class="actividad">
      <li :for={{fecha, usuario, accion, detalle, resultado} <- @entradas}>
        <span class="tenue">{Calendar.strftime(fecha, "%H:%M:%S")}</span>
        <strong>{usuario}</strong>
        <code>{accion}</code>
        <span class="actividad-detalle">{detalle}</span>
        <span class={"insignia insignia-#{if resultado == "ok", do: "verde", else: "rojo"}"}>
          {resultado}
        </span>
      </li>
    </ul>
    """
  end
end
