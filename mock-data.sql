-- Taskavista — sample content.
--
-- Not part of the schema: run dashboard/sql/init.sql first, then this only when you want a
-- database with something in it. Re-runnable — it seeds an empty table and
-- does nothing otherwise.

-- The working directories are under the root in config-dev.json.
insert into projects (name, slug, description, ai_paused, working_dir)
select name, slug, description, not managed, '~/taskavista-projects-dev/' || slug
from (values
	('Website relaunch', 'website-relaunch',
		'The new marketing site, from design to launch day. The old site stays up until the new one has passed review.',
		false),
	('Q3 finance', 'q3-finance', '', false),
	('Локализация сайта', 'локализация-сайта', 'Перевод сайта на русский, японский, арабский и греческий.', false),
	('AI test', 'ai-test',
		'A playground for the AI agents. Keep task descriptions short, and leave tasks in "Done" alone.',
		true)
) as seed(name, slug, description, managed)
where not exists (select 1 from projects);

-- Each project's lanes take new tasks in the first lane only, or in any, and are picked up by
-- the agents in all of them or in none.
insert into lanes (project_id, name, position, color, marks_done, accepts_new_tasks, agents_pick_up)
select p.id, seed.name, seed.position, seed.color, seed.marks_done,
	seed.position = 0 or rule.any_lane, rule.managed
from (values
	('website-relaunch', 'To do', 0, '#8fa6ff', false),
	('website-relaunch', 'In progress', 1, '#e8b154', false),
	('website-relaunch', 'Done', 2, '#5fd6ab', true),
	('q3-finance', 'To do', 0, '#8fa6ff', false),
	('q3-finance', 'In progress', 1, '#e8b154', false),
	('q3-finance', 'To audit', 2, '#c49bf0', false),
	('q3-finance', 'Done', 3, '#5fd6ab', true),
	('локализация-сайта', 'Нужно сделать', 0, '#8fa6ff', false),
	('локализация-сайта', '翻訳中', 1, '#e8b154', false),
	('локализация-сайта', 'مراجعة', 2, '#c49bf0', false),
	('локализация-сайта', 'Έλεγχος', 3, '#6fc7e8', false),
	('локализация-сайта', 'पूर्ण', 4, '#5fd6ab', true),
	('ai-test', 'To do', 0, '#8fa6ff', false),
	('ai-test', 'In progress', 1, '#e8b154', false),
	('ai-test', 'Done', 2, '#5fd6ab', true)
) as seed(slug, name, position, color, marks_done)
join (values
	('website-relaunch', false, false),
	('q3-finance', true, false),
	('локализация-сайта', true, false),
	('ai-test', false, true)
) as rule(slug, any_lane, managed) on rule.slug = seed.slug
join projects p on p.slug = seed.slug
where not exists (select 1 from lanes);

insert into tasks (lane_id, description, position)
select l.id, seed.description, seed.position
from (values
	('website-relaunch', 'To do', 'Write the onboarding email for new teammates', 0),
	('website-relaunch', 'To do', 'Book the offsite room', 1),
	('website-relaunch', 'In progress', 'Rebuild the weekly report so it pulls live numbers', 0),
	('website-relaunch', 'In progress', 'Rewrite the pricing page copy', 1),
	('website-relaunch', 'Done', 'Send the September invoice to Halden', 0),
	('website-relaunch', 'Done', 'Fix the broken link in the footer', 1),
	('q3-finance', 'To do', 'Collect Q3 invoices from the two vendors', 0),
	('q3-finance', 'To do', 'Chase the late invoice from Perrin', 1),
	('q3-finance', 'In progress', 'Reconcile the vendor invoice log', 0),
	('локализация-сайта', 'Нужно сделать', 'Собрать все строки интерфейса в один файл', 0),
	('локализация-сайта', 'Нужно сделать', '한국어 번역가를 찾기', 1),
	('локализация-сайта', 'Нужно сделать', 'Перевести страницу «О нас»', 2),
	('локализация-сайта', '翻訳中', 'トップページを日本語に翻訳する', 0),
	('локализация-сайта', '翻訳中', 'हिन्दी में सहायता लेख अनुवाद करना', 1),
	('локализация-сайта', 'مراجعة', 'ترجمة صفحة الأسعار إلى العربية', 0),
	('локализация-сайта', 'مراجعة', 'בדיקת כיוון הטקסט בעברית', 1),
	('локализация-сайта', 'Έλεγχος', 'Μετάφραση του μενού στα ελληνικά', 0),
	('локализация-сайта', 'Έλεγχος', 'Проверить русские формы склонения в письмах', 1),
	('локализация-сайта', 'पूर्ण', '把注册表单翻译成中文', 0),
	('локализация-сайта', 'पूर्ण', 'แปลข้อความแจ้งเตือนเป็นภาษาไทย', 1)
) as seed(slug, lane, description, position)
join projects p on p.slug = seed.slug
join lanes l on l.project_id = p.id and l.name = seed.lane
where not exists (select 1 from tasks);

insert into task_notes (task_id, inserted_at, note, lane_color)
select t.id, t.created_at, format('Created in "%s"', l.name), l.color
from tasks t
join lanes l on l.id = t.lane_id
where not exists (select 1 from task_notes);
