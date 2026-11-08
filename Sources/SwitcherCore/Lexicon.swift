/// Встроенные списки слов. Системная проверка орфографии знает почти всё,
/// но не знает частотности: для неё «vs» и «мы» одинаково правильные.
/// Здесь — частые слова (им доверяем сильнее) и словарь кода и терминала.
public enum Lexicon {
    /// Частые слова. Короткие слова (1–2 буквы) считаются словами, только если они есть здесь.
    public static func common(_ lang: Lang) -> Set<String> {
        lang == .ru ? ru : en
    }

    static let ru: Set<String> = words("""
    а в и к о с у я
    бы во да до же за из им их ко ли мы на не ни но ну об он от по со то ты уж вы ей ой ох ах эх ух ок
    шт кг км см мм мл гр др пр ул тыс млн млрд руб мин сек
    без был вам вас вот все всё всем всех где два для его ее её ему еще ещё или как кто мне мой моя мои над нам нас нет них они она оно под при про раз сам так там тем тех тот три тут уже чем что эта эти это эту
    была были было быть будет буду будем будут весь вся всего день дела дело дома друг если есть даже даже жизнь здесь знаю какой какая какие какое когда конечно короче кстати ладно лучше люди меня много может можно надо наш ваш нужно один одна очень пока после потом почему привет просто работа сегодня сейчас себя себе сказал сказать слова слово спасибо стал так тебе тебя тоже только хорошо хочу хочешь чтобы этого этом этот вообще вроде давай давайте завтра вчера зачем понял поняла понятно наверное типа туда сюда своя свой свои свою твой твоя который которая которые человек время время год года делать сделать думаю знать могу можешь говорить мама папа ребята окей ага неа угу
    """)

    static let en: Set<String> = words("""
    a i
    am an as at be by do go he hi if in is it me my no of ok on or so to up us we
    all and any are but can day did for get got had has her him his how its let may new not now old one our out own say see she the too two use was way who why yes yet you
    about after again also back been best both came come could does done down each even every first from give good great have hello here into just know last like long look made make many more most much must need never next only other over part people really right said same should show some still such take than thank thanks that their them then there these they thing think this those time very want well were what when where which while will with work would year your
    okay please sorry hey cool nice
    """)

    /// Слова из кода и терминала. Считаются английскими «наверняка», поэтому
    /// `пше` превращается в `git`, а `св` — в `cd`.
    public static let code: Set<String> = words("""
    git gh ls cd rm mv cp mkdir rmdir touch cat less grep find sed awk curl wget ssh scp sudo chmod chown
    ps kill killall top htop df du tar zip unzip brew npm npx pnpm yarn node bun deno pip pip3 python python3
    swift swiftc xcodebuild make cmake gcc clang cargo rustc java mvn gradle docker kubectl helm terraform
    aws gcloud vim nvim nano code open echo export env which man history clear exit source alias pwd
    crontab launchctl defaults ping lsof tail head sort uniq wc diff xargs tee jq yq claude
    http https localhost json yaml yml toml xml html css scss js ts jsx tsx md py rb sh zsh bash sql
    api url uri ui ux ci pr repo src lib bin usr etc tmp dist build config dev prod staging
    main master origin stash rebase checkout commit push pull fetch merge branch clone init status log
    add reset revert tag func fn def let var const val int str bool void nil null true false self this
    async await return import from struct enum class impl trait pub mut println printf print console
    else elif for while try catch throw throws guard switch case break continue todo fixme readme
    wip regex stdout stderr stdin tcp udp ip dns vpn os cpu gpu ram ssd usb macos ios linux llm ai gpt
    """)

    private static func words(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: { $0.isWhitespace }).map(String.init))
    }
}
