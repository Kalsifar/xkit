// XKIT TUI — отдельный UI-процесс; вся конфигурация выполняется ядром xkit.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

const version = "5.3.1"

type protocol struct {
	ID        string `json:"id"`
	Title     string `json:"title"`
	Kind      string `json:"kind"`
	Installed bool   `json:"installed"`
	Status    string `json:"status"`
	Details   string `json:"details"`
}

type nodeMetric struct {
	Name          string   `json:"name"`
	Status        string   `json:"status"`
	Panel         string   `json:"panel"`
	LatencyMS     *int     `json:"latency_ms"`
	CPUPercent    *float64 `json:"cpu_pct"`
	RAMPercent    *float64 `json:"ram_pct"`
	Load1         *float64 `json:"load1"`
	Total         int64    `json:"total"`
	Clients       int      `json:"clients"`
	Resources     string   `json:"resources"`
	RateBps       *float64 `json:"rate_bps"`
	IntervalTotal *int64   `json:"interval_total"`
}

type snapshot struct {
	Host             string       `json:"host"`
	Mode             string       `json:"mode"`
	Nodes            int          `json:"nodes"`
	NodesOK          int          `json:"nodes_ok"`
	Clients          int          `json:"clients"`
	Nginx            bool         `json:"nginx"`
	XUI              bool         `json:"xui"`
	Xray             bool         `json:"xray"`
	CertDays         int          `json:"cert_days"`
	BackupHours      int          `json:"backup_hours"`
	Protocols        []protocol   `json:"protocols"`
	NodeMetrics      []nodeMetric `json:"nodes_metrics"`
	MetricsGenerated int64        `json:"metrics_generated"`
	Generated        string       `json:"generated"`
}

type page int

const (
	pageMain page = iota
	pageUsers
	pageProtocols
	pageNodes
	pageMonitoring
	pageService
	pageSettings
	pageHelp
)

type item struct {
	title string
	desc  string
	page  page
	args  []string
}

type model struct {
	xkit       string
	page       page
	cursor     int
	items      []item
	snap       snapshot
	loading    bool
	width      int
	height     int
	notice     string
	err        string
	filtering  bool
	filter     string
	showHelp   bool
	lastUpdate time.Time
}

type snapshotMsg struct {
	snap snapshot
	err  error
}

type actionDoneMsg struct{ err error }
type tickMsg time.Time

var (
	cyan     = lipgloss.Color("#63E6BE")
	blue     = lipgloss.Color("#74C0FC")
	muted    = lipgloss.Color("#8291A6")
	green    = lipgloss.Color("#69DB7C")
	red      = lipgloss.Color("#FF8787")
	yellow   = lipgloss.Color("#FFD43B")
	panel    = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(lipgloss.Color("#334155")).Padding(0, 1)
	titleBar = lipgloss.NewStyle().Foreground(lipgloss.Color("#0B1220")).Background(cyan).Bold(true).Padding(0, 1)
	selected = lipgloss.NewStyle().Foreground(lipgloss.Color("#0B1220")).Background(blue).Bold(true)
	dim      = lipgloss.NewStyle().Foreground(muted)
	good     = lipgloss.NewStyle().Foreground(green)
	bad      = lipgloss.NewStyle().Foreground(red)
	warn     = lipgloss.NewStyle().Foreground(yellow)
)

func initialModel(xkit string) model {
	m := model{xkit: xkit, page: pageMain, loading: true, width: 92, height: 30}
	m.items = mainItems()
	return m
}

func mainItems() []item {
	return []item{
		{"Пользователи и подписки", "Создание, ссылки, квоты и сброс трафика", pageUsers, nil},
		{"Протоколы и подключения", "REALITY, XHTTP, AmneziaWG и Hysteria 2", pageProtocols, nil},
		{"Ноды и балансировка", "Пул серверов, туннели и стратегии", pageNodes, nil},
		{"Мониторинг", "Дашборд, Telegram и сроки аренды", pageMonitoring, nil},
		{"Обслуживание", "Health-check, маршруты, бэкапы и обновления", pageService, nil},
		{"Настройки и справка", "Классический интерфейс и горячие клавиши", pageSettings, nil},
	}
}

func itemsFor(p page, s snapshot) []item {
	switch p {
	case pageUsers:
		return []item{
			{"Создать пользователя", "UUID, subId, квота, срок и flow", pageMain, []string{"client", "add"}},
			{"Список и ссылки", "Пользователи, трафик и ссылки подключения", pageMain, []string{"client", "list"}},
			{"Удалить пользователя", "Удаление через API панели", pageMain, []string{"client", "del"}},
			{"Сбросить трафик", "Обнулить потреблённый трафик", pageMain, []string{"client", "reset"}},
			{"Перегенерировать подписки", "Обновить файлы и показать URL", pageMain, []string{"sub"}},
		}
	case pageProtocols:
		rows := []item{
			{"VLESS + REALITY + Vision", "Основной TCP-профиль; мастер создания inbound", pageMain, []string{"reality"}},
			{"VLESS + XHTTP + REALITY", "Альтернативный транспорт с проверкой и откатом", pageMain, []string{"protocols", "xhttp"}},
			{"AmneziaWG", "Отдельная VPN-служба, клиенты и конфиги", pageMain, []string{"protocols", "awg"}},
			{"Hysteria 2", "Отдельная UDP-служба, Salamander и ссылки", pageMain, []string{"protocols", "hysteria2"}},
			{"Сводка протоколов", "Состояние служб и активных профилей", pageMain, []string{"protocols", "status"}},
		}
		for i := range rows[2:4] {
			for _, p := range s.Protocols {
				if (i == 0 && p.ID == "awg") || (i == 1 && p.ID == "hysteria2") {
					rows[i+2].desc = p.Details + " • " + p.Status
				}
			}
		}
		return rows
	case pageNodes:
		return []item{
			{"Управление нодами", "Добавление, удаление, repair, repin и стратегия", pageMain, []string{"nodes"}},
			{"Обновить метрики нод", "Трафик, скорость, ping и системные CPU/RAM", pageMain, []string{"nodes", "metrics"}},
			{"Проверка сервера и портов", "Сервисы, маршруты и внешние порты", pageMain, []string{"status"}},
		}
	case pageMonitoring:
		return []item{
			{"Веб-дашборд", "Установка, URL, ротация и удаление", pageMain, []string{"dash"}},
			{"Telegram-алерты", "Настройка, проверка и тестовая доставка", pageMain, []string{"telegram"}},
			{"Сроки аренды", "Мастер и ноды, даты и заметки", pageMain, []string{"expiry"}},
			{"Реквизиты", "Сводка с маскированными паролями", pageMain, []string{"info"}},
		}
	case pageService:
		return []item{
			{"Проверка жизнеспособности", "Полный health-check сервера", pageMain, []string{"health"}},
			{"Автопроброс инбаундов", "Проверка nginx и автоматический откат", pageMain, []string{"route", "--yes"}},
			{"Создать бэкап", "БД панели, nginx, сертификаты и состояние", pageMain, []string{"backup"}},
			{"Восстановить бэкап", "Безопасная проверка архива перед restore", pageMain, []string{"restore"}},
			{"Обновить XKIT", "SHA-256, резервные копии и атомарная замена", pageMain, []string{"update"}},
			{"Установка и сертификаты", "Существующий мастер установки и настройки", pageMain, []string{"install"}},
		}
	case pageSettings:
		return []item{
			{"Классическое меню", "Выйти из TUI и открыть Bash-интерфейс", pageMain, []string{"--classic"}},
			{"Горячие клавиши", "Навигация, поиск и обновление", pageHelp, nil},
		}
	}
	return mainItems()
}

func findXkit(explicit string) string {
	if explicit != "" {
		return explicit
	}
	if v := os.Getenv("XKIT_BIN"); v != "" {
		return v
	}
	if v, err := exec.LookPath("xkit"); err == nil {
		return v
	}
	if exe, err := os.Executable(); err == nil {
		candidate := filepath.Join(filepath.Dir(exe), "xkit")
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	if _, err := os.Stat("xkit.sh"); err == nil {
		return "xkit.sh"
	}
	return "xkit"
}

const actionPauseScript = `
"$@"
rc=$?
printf '\n'
if [ "$rc" -eq 0 ]; then
	printf 'Команда завершена успешно.\n'
else
	printf 'Команда завершилась с кодом %s.\n' "$rc"
fi
printf 'Enter — вернуться в XKIT TUI...'
if [ -t 0 ] && { exec 9</dev/tty; } 2>/dev/null; then
	IFS= read -r _ <&9 || true
	exec 9<&-
else
	IFS= read -r _ || true
fi
printf '\n'
exit "$rc"
`

func actionArgv(path string, args []string) []string {
	if strings.HasSuffix(path, ".sh") {
		return append([]string{"bash", path}, args...)
	}
	return append([]string{path}, args...)
}

func actionCommand(path string, args []string) *exec.Cmd {
	argv := actionArgv(path, args)
	wrapperArgs := append([]string{"-c", actionPauseScript, "xkit-action"}, argv...)
	return exec.Command("bash", wrapperArgs...)
}

func fetchSnapshot(path string) tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		var cmd *exec.Cmd
		if strings.HasSuffix(path, ".sh") {
			cmd = exec.CommandContext(ctx, "bash", path, "snapshot")
		} else {
			cmd = exec.CommandContext(ctx, path, "snapshot")
		}
		out, err := cmd.Output()
		if err != nil {
			return snapshotMsg{err: fmt.Errorf("xkit snapshot: %w", err)}
		}
		var s snapshot
		if err := json.Unmarshal(out, &s); err != nil {
			return snapshotMsg{err: fmt.Errorf("некорректный snapshot: %w", err)}
		}
		return snapshotMsg{snap: s}
	}
}

func runAction(path string, args []string) tea.Cmd {
	cmd := actionCommand(path, args)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Env = append(os.Environ(), "XKIT_TUI=0")
	return tea.ExecProcess(cmd, func(err error) tea.Msg { return actionDoneMsg{err: err} })
}

func tick() tea.Cmd { return tea.Tick(10*time.Second, func(t time.Time) tea.Msg { return tickMsg(t) }) }

func (m model) Init() tea.Cmd { return tea.Batch(fetchSnapshot(m.xkit), tick()) }

func visibleItems(m model) []item {
	if m.filter == "" {
		return m.items
	}
	needle := strings.ToLower(m.filter)
	out := make([]item, 0, len(m.items))
	for _, it := range m.items {
		if strings.Contains(strings.ToLower(it.title+" "+it.desc), needle) {
			out = append(out, it)
		}
	}
	return out
}

func (m model) enter() (tea.Model, tea.Cmd) {
	rows := visibleItems(m)
	if len(rows) == 0 || m.cursor >= len(rows) {
		return m, nil
	}
	it := rows[m.cursor]
	m.filter = ""
	if it.args != nil {
		m.notice = "Выполняется: xkit " + strings.Join(it.args, " ")
		return m, runAction(m.xkit, it.args)
	}
	m.page = it.page
	m.items = itemsFor(m.page, m.snap)
	m.cursor = 0
	return m, nil
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		return m, nil
	case snapshotMsg:
		m.loading = false
		m.lastUpdate = time.Now()
		if msg.err != nil {
			m.err = msg.err.Error()
		} else {
			m.err = ""
			m.snap = msg.snap
			if m.page == pageProtocols {
				m.items = itemsFor(m.page, m.snap)
			}
		}
		return m, nil
	case actionDoneMsg:
		m.loading = true
		if msg.err != nil {
			m.notice = "Команда завершилась: " + msg.err.Error()
		} else {
			m.notice = "Готово. Состояние обновлено."
		}
		return m, fetchSnapshot(m.xkit)
	case tickMsg:
		if !m.loading {
			m.loading = true
			return m, tea.Batch(fetchSnapshot(m.xkit), tick())
		}
		return m, tick()
	case tea.KeyMsg:
		if m.filtering {
			switch msg.Type {
			case tea.KeyEsc:
				m.filtering, m.filter = false, ""
			case tea.KeyEnter:
				m.filtering = false
				m.cursor = 0
			case tea.KeyBackspace:
				if m.filter != "" {
					_, n := utf8.DecodeLastRuneInString(m.filter)
					m.filter = m.filter[:len(m.filter)-n]
				}
			case tea.KeyRunes:
				m.filter += string(msg.Runes)
				m.cursor = 0
			}
			return m, nil
		}
		switch msg.String() {
		case "ctrl+c":
			return m, tea.Quit
		case "q", "esc":
			if m.page == pageMain {
				return m, tea.Quit
			}
			m.page, m.items, m.cursor, m.filter = pageMain, mainItems(), 0, ""
			return m, nil
		case "up", "k":
			if m.cursor > 0 {
				m.cursor--
			}
		case "down", "j":
			if m.cursor < len(visibleItems(m))-1 {
				m.cursor++
			}
		case "home":
			m.cursor = 0
		case "end":
			m.cursor = max(0, len(visibleItems(m))-1)
		case "enter":
			return m.enter()
		case "/":
			m.filtering, m.filter = true, ""
		case "r":
			m.loading = true
			return m, fetchSnapshot(m.xkit)
		case "?":
			m.page, m.items, m.cursor = pageHelp, nil, 0
			return m, nil
		}
	}
	return m, nil
}

func service(ok bool, name string) string {
	if ok {
		return good.Render("● " + name)
	}
	return bad.Render("● " + name)
}

func pageTitle(p page) string {
	switch p {
	case pageUsers:
		return "Пользователи и подписки"
	case pageProtocols:
		return "Протоколы и подключения"
	case pageNodes:
		return "Ноды и балансировка"
	case pageMonitoring:
		return "Мониторинг"
	case pageService:
		return "Обслуживание"
	case pageSettings:
		return "Настройки"
	case pageHelp:
		return "Горячие клавиши"
	}
	return "Обзор"
}

func (m model) header() string {
	mode := m.snap.Mode
	if mode == "" {
		mode = "не настроен"
	}
	host := m.snap.Host
	if host == "" {
		host = "XKIT"
	}
	return titleBar.Render(" XKIT "+version+" ") + "  " + lipgloss.NewStyle().Bold(true).Render(host) + dim.Render("  •  "+mode)
}

func (m model) statusPanel() string {
	cert := "—"
	if m.snap.CertDays >= 0 {
		cert = fmt.Sprintf("%d дн.", m.snap.CertDays)
	}
	backup := "нет"
	if m.snap.BackupHours >= 0 {
		if m.snap.BackupHours < 24 {
			backup = fmt.Sprintf("%d ч. назад", m.snap.BackupHours)
		} else {
			backup = fmt.Sprintf("%d дн. назад", m.snap.BackupHours/24)
		}
	}
	line1 := service(m.snap.Nginx, "nginx") + "   " + service(m.snap.XUI, "3X-UI") + "   " + service(m.snap.Xray, "Xray")
	line2 := dim.Render("Ноды ") + fmt.Sprintf("%d/%d", m.snap.NodesOK, m.snap.Nodes) + dim.Render("    Клиенты ") + fmt.Sprintf("%d", m.snap.Clients) + dim.Render("    SSL ") + cert + dim.Render("    Бэкап ") + backup
	return panel.Render(line1 + "\n" + line2)
}

func formatMetricBytes(v float64, suffix bool) string {
	units := []string{"B", "KB", "MB", "GB", "TB"}
	i := 0
	for v >= 1000 && i < len(units)-1 {
		v /= 1000
		i++
	}
	if i == 0 {
		return fmt.Sprintf("%.0f %s", v, units[i]) + map[bool]string{true: "/s", false: ""}[suffix]
	}
	return fmt.Sprintf("%.1f %s", v, units[i]) + map[bool]string{true: "/s", false: ""}[suffix]
}

func metricPercent(v *float64) string {
	if v == nil {
		return "—"
	}
	return fmt.Sprintf("%.0f%%", *v)
}

func (m model) nodesMetricsPanel() string {
	if m.snap.Nodes == 0 {
		return ""
	}
	if len(m.snap.NodeMetrics) == 0 {
		return panel.Render(dim.Render("Метрики ещё не собраны. Выберите «Обновить метрики нод»."))
	}
	active := ""
	var maxRate float64
	for _, n := range m.snap.NodeMetrics {
		if n.RateBps != nil && *n.RateBps > maxRate {
			maxRate, active = *n.RateBps, n.Name
		}
	}
	var b strings.Builder
	b.WriteString(dim.Render("Нода         Туннель  Панель  Ping     CPU    RAM    Скорость/интервал  Трафик"))
	for _, n := range m.snap.NodeMetrics {
		name := n.Name
		if len(name) > 11 {
			name = name[:11]
		}
		if n.Name == active {
			name = "★" + name
		} else {
			name = " " + name
		}
		ping, rate, traffic := "—", "—", "—"
		if n.LatencyMS != nil {
			ping = fmt.Sprintf("%d ms", *n.LatencyMS)
		}
		if n.RateBps != nil {
			rate = formatMetricBytes(*n.RateBps, true)
		}
		if n.IntervalTotal != nil {
			traffic = formatMetricBytes(float64(*n.IntervalTotal), false)
		}
		status := n.Status
		if status == "ok" {
			status = good.Render("OK")
		} else {
			status = bad.Render("DOWN")
		}
		b.WriteString("\n" + fmt.Sprintf("%-12s %-8s %-7s %-8s %-6s %-6s %-18s %s",
			name, status, n.Panel, ping, metricPercent(n.CPUPercent), metricPercent(n.RAMPercent), rate, traffic))
	}
	age := ""
	if m.snap.MetricsGenerated > 0 {
		seconds := int64(time.Since(time.Unix(m.snap.MetricsGenerated, 0)).Seconds())
		if seconds < 0 {
			seconds = 0
		}
		age = fmt.Sprintf(" • обновлено %d с назад", seconds)
		if seconds > 600 {
			age += " • данные устарели"
		}
	}
	b.WriteString("\n" + dim.Render("★ самая активная за интервал; CPU/RAM — системные"+age))
	return panel.Render(b.String())
}

func (m model) helpView() string {
	return panel.Render(lipgloss.NewStyle().Bold(true).Foreground(cyan).Render("Управление") + "\n\n" +
		"↑ / ↓, j / k   навигация\n" +
		"Enter          открыть или выполнить\n" +
		"Esc / q        назад; на главном экране — выход\n" +
		"/              поиск по текущему разделу\n" +
		"r              обновить состояние\n" +
		"?              эта справка\n" +
		"Ctrl+C         немедленный выход\n\n" +
		dim.Render("Команды выполняются существующим ядром XKIT. После завершения\nнажмите Enter в классическом интерфейсе, если оно этого попросит."))
}

func (m model) View() string {
	if m.width < 40 || m.height < 12 {
		return "XKIT TUI: увеличьте окно терминала (минимум 40×12).\n"
	}
	var b strings.Builder
	b.WriteString(m.header() + "\n\n")
	if m.page == pageMain {
		b.WriteString(m.statusPanel() + "\n\n")
	}
	if m.page == pageNodes {
		if metrics := m.nodesMetricsPanel(); metrics != "" {
			b.WriteString(metrics + "\n\n")
		}
	}
	b.WriteString(lipgloss.NewStyle().Foreground(cyan).Bold(true).Render(pageTitle(m.page)) + "\n\n")
	if m.page == pageHelp {
		b.WriteString(m.helpView() + "\n")
	} else {
		rows := visibleItems(m)
		if len(rows) == 0 {
			b.WriteString(dim.Render("Ничего не найдено. Esc — очистить поиск.") + "\n")
		}
		for i, it := range rows {
			marker := "  "
			title := it.title
			if i == m.cursor {
				marker = "❯ "
				title = selected.Render(" " + title + " ")
			}
			b.WriteString(marker + title + "\n")
			b.WriteString("    " + dim.Render(it.desc) + "\n")
		}
	}
	if m.filtering || m.filter != "" {
		b.WriteString("\n" + warn.Render("/ "+m.filter) + dim.Render("  Enter — применить, Esc — отмена") + "\n")
	}
	if m.notice != "" {
		b.WriteString("\n" + dim.Render(m.notice) + "\n")
	}
	if m.err != "" {
		b.WriteString("\n" + bad.Render("Состояние недоступно: "+m.err) + "\n")
	}
	footer := "↑↓ навигация   Enter выбрать   / поиск   r обновить   ? помощь   q назад/выход"
	if m.loading {
		footer = "обновление…   " + footer
	}
	b.WriteString("\n" + dim.Render(footer))
	return b.String()
}

func main() {
	var xkit string
	var selftest bool
	var showVersion bool
	flag.StringVar(&xkit, "xkit", "", "путь к команде xkit")
	flag.BoolVar(&selftest, "selftest", false, "проверить запуск без TTY")
	flag.BoolVar(&showVersion, "version", false, "показать версию")
	flag.Parse()
	if showVersion {
		fmt.Println(version)
		return
	}
	if selftest {
		m := initialModel(findXkit(xkit))
		if len(mainItems()) != 6 || m.page != pageMain {
			os.Exit(1)
		}
		fmt.Println("XKIT TUI selftest: OK")
		return
	}
	if !isTerminal() {
		fmt.Fprintln(os.Stderr, "XKIT TUI требует терминал. Используйте xkit --classic или XKIT_TUI=0 xkit.")
		os.Exit(2)
	}
	p := tea.NewProgram(initialModel(findXkit(xkit)), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "Ошибка TUI:", err)
		os.Exit(1)
	}
}

func isTerminal() bool {
	// bubbletea сам обработает возможности терминала; здесь отсекаем cron/pipe.
	for _, f := range []struct {
		name string
		fd   uintptr
	}{{"stdin", 0}, {"stdout", 1}} {
		fi, err := os.Stat("/proc/self/fd/" + fmt.Sprint(f.fd))
		_ = f.name
		if err != nil || fi.Mode()&os.ModeCharDevice == 0 {
			return false
		}
	}
	return true
}
