"""Reading a search (#46): people, projects, organizations, dates and where
to look, taken out of the text as filters; the rest are words."""

from datetime import date

from palaver import search

TODAY = date(2026, 10, 29)  # a Thursday
VOCAB = search.Vocabulary(
    people=["Anna Berger", "Anna Schmidt", "Tom", "Henrik Huber", "Mara", "Will Smith"],
    projects={"p1": "ÖNW", "p2": "Software Foundry"},
    orgs=["ACB", "KLOUD"],
)


def parse(text, vocab=VOCAB):
    return search.parse(text, vocab, today=TODAY)


def kinds(q):
    return [(f.kind, f.value) for f in q.filters]


def test_plain_words_stay_words():
    q = parse("nothing like this")
    assert q.words == ["nothing", "like", "this"] and q.filters == []
    assert parse("pelican").words == ["pelican"]
    assert parse("   ").words == []


def test_two_people_must_both_have_taken_part():
    q = parse("Anna and Tom")
    assert kinds(q) == [("person", "Anna"), ("person", "Tom")]
    assert q.words == [] and not q.any_person
    assert parse("anna or tom").any_person  # either of them


def test_a_full_name_is_one_person_and_a_unique_first_name_becomes_the_full_name():
    assert kinds(parse("anna berger")) == [("person", "Anna Berger")]
    assert kinds(parse("henrik")) == [("person", "Henrik Huber")]
    assert kinds(parse("Huber")) == [("person", "Henrik Huber")]


def test_a_person_and_a_topic():
    q = parse("with Henrik about the software foundry")
    assert kinds(q) == [("person", "Henrik Huber"), ("project", "p2")]
    assert q.words == []
    other = search.Vocabulary(people=VOCAB.people, projects={}, orgs=[])
    q = parse("with Henrik about the software foundry", other)
    assert kinds(q) == [("person", "Henrik Huber")]
    assert q.words == ["software", "foundry"]  # the little words go once something was understood


def test_a_project_and_a_time_range():
    q = parse("ÖNW last month")
    assert kinds(q) == [("project", "p1"), ("since", "2026-09-01"), ("until", "2026-09-30")]
    assert q.since == date(2026, 9, 1) and q.until == date(2026, 9, 30)
    assert [f.label for f in q.filters] == ["ÖNW", "Last month", "Last month"]


def test_dates_in_english_and_german():
    def span(text):
        q = parse(text)
        return (q.since, q.until)

    assert span("today") == (TODAY, TODAY)
    assert span("gestern") == (date(2026, 10, 28), date(2026, 10, 28))
    assert span("this week") == (date(2026, 10, 26), TODAY)
    assert span("letzte Woche") == (date(2026, 10, 19), date(2026, 10, 25))
    assert span("diesen Monat") == (date(2026, 10, 1), TODAY)
    assert span("oktober") == (date(2026, 10, 1), date(2026, 10, 31))
    assert span("december") == (date(2025, 12, 1), date(2025, 12, 31))  # the last one, not one to come
    assert span("march 2026") == (date(2026, 3, 1), date(2026, 3, 31))
    assert span("2026-10-21") == (date(2026, 10, 21), date(2026, 10, 21))
    assert span("2026-02") == (date(2026, 2, 1), date(2026, 2, 28))
    assert span("since 2026-10-01") == (date(2026, 10, 1), None)
    assert span("before october") == (None, date(2026, 9, 30))
    assert span("after 2026-10-20") == (date(2026, 10, 21), None)
    assert span("seit september") == (date(2026, 9, 1), None)


def test_what_was_decided():
    q = parse("what did we decide about the test phase")
    assert q.scope == "decisions" and q.words == ["test", "phase"]
    assert kinds(q) == [("in", "decisions")]
    assert parse("was wurde zur Testphase beschlossen").scope == "decisions"
    q = parse("next steps for ÖNW")
    assert q.scope == "steps" and kinds(q) == [("in", "steps"), ("project", "p1")] and q.words == []


def test_lines_a_person_said():
    q = parse("where did Mara talk about pricing")
    assert kinds(q) == [("person", "Mara"), ("said", "Mara")]
    assert q.said_by == "Mara" and q.words == ["pricing"]
    assert parse("was hat Mara zu den Kosten gesagt").said_by == "Mara"


def test_an_organization():
    q = parse("meetings with ACB people")
    assert kinds(q) == [("org", "ACB")] and q.words == []


def test_quotes_keep_a_name_a_word():
    q = parse('"Anna" budget')
    assert q.filters == [] and q.words == ["Anna", "budget"]
    q = parse('"software foundry" Tom')
    assert q.words == ["software foundry"] and kinds(q) == [("person", "Tom")]


def test_little_words_are_never_names():
    q = parse("what will Anna do")
    assert kinds(q) == [("person", "Anna")]
    assert q.words == []  # a question: "what will … do" are little words
    assert kinds(parse("will smith")) == [("person", "Will Smith")]  # the full name is


def test_written_out_filters():
    q = parse('person:"Anna Berger" project:önw org:acb since:2026-10-01 until:2026-10-15 '
              'in:steps is:reviewed has:steps by:Tom budget')
    assert kinds(q) == [("person", "Anna Berger"), ("project", "p1"), ("org", "ACB"), ("since", "2026-10-01"),
                        ("until", "2026-10-15"), ("in", "steps"), ("is", "reviewed"), ("has", "steps"),
                        ("person", "Tom"), ("said", "Tom")]
    assert q.words == ["budget"] and q.reviewed is True and q.has_steps
    assert parse("is:unreviewed").reviewed is False
    unknown = parse("project:nope")
    assert kinds(unknown) == [("project", None)] and unknown.filters[0].label == "nope"  # finds nothing


def test_each_filter_knows_where_it_is_in_the_text():
    text = "Anna and Tom last month"
    q = parse(text)
    assert [text[a:b] for a, b in (f.span for f in q.filters)] == ["Anna", "Tom", "last month", "last month"]


def test_the_chips_the_page_shows():
    chips = parse("Anna and Tom last month in:decisions").chips()
    assert chips == [
        {"kind": "person", "label": "Anna", "title": "Took part: named speaker or invited", "span": [0, 4],
         "text": "Anna", "written": False},
        {"kind": "person", "label": "Tom", "title": "Took part: named speaker or invited", "span": [9, 12],
         "text": "Tom", "written": False},
        {"kind": "date", "label": "Last month", "title": "2026-09-01 to 2026-09-30", "span": [13, 23],
         "text": "last month", "written": False},
        {"kind": "in", "label": "In decisions", "title": "Only decisions in the notes", "span": [24, 36],
         "text": "in:decisions", "written": True},
    ]
    assert parse("anna or tom").chips()[0]["title"] == "Took part, any of them: named speaker or invited"


def test_a_one_word_project_is_a_filter_only_when_nothing_else_is_searched():
    vocab = search.Vocabulary(people=["Mara"], projects={"p1": "Search", "p2": "Software Foundry"}, orgs=[])
    q = parse("search ranking", vocab)
    assert q.filters == [] and q.words == ["search", "ranking"]  # not the project "Search"
    assert kinds(parse("Search last month", vocab))[0] == ("project", "p1")
    assert kinds(parse("project:search ranking", vocab)) == [("project", "p1")]
    q = parse("software foundry pricing", vocab)
    assert kinds(q) == [("project", "p2")] and q.words == ["pricing"]  # a whole longer name is


def test_short_parts_of_names_stay_words():
    vocab = search.Vocabulary(people=["Tom Kraus", "Eli", "Thomas Berg"], projects={}, orgs=[])
    assert parse("tom", vocab).filters == []  # "Tom" of Tom Kraus: under four letters
    assert kinds(parse("Kraus", vocab)) == [("person", "Tom Kraus")]
    assert kinds(parse("tom kraus", vocab)) == [("person", "Tom Kraus")]
    assert kinds(parse("eli", vocab)) == [("person", "Eli")]  # a whole name
    assert kinds(parse("thomas", vocab)) == [("person", "Thomas Berg")]


def test_a_chip_knows_its_text_and_whether_it_was_written_out():
    chips = parse('Anna project:ÖNW').chips()
    assert [(c["text"], c["written"]) for c in chips] == [("Anna", False), ("project:ÖNW", True)]
