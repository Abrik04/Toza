# Toza — мобильное приложение (PWA)

Устанавливается на телефон как обычное приложение, работает офлайн.

## Запуск на GitHub Pages
1. Создайте репозиторий (Public) и перетащите ВСЕ файлы из архива в него (Add file -> Upload files), нажмите Commit.
2. Settings -> Pages -> Branch: main, папка / (root) -> Save.
3. Откройте https://ВАШ-ЛОГИН.github.io/ИМЯ-РЕПОЗИТОРИЯ/ на телефоне.
4. iPhone: Safari -> Поделиться -> На экран Домой. Android: меню Chrome -> Установить приложение.

## Настройки: файл config.js
Всё, что вы меняете под свой бизнес, лежит в config.js: Telegram (tg), телефон (phone), минимальный чек, промокоды,
уровни лояльности (levels), цены, допуслуги, районы, время и ключи Supabase (sb).
Обновления приложения меняют только index.html, поэтому ваши настройки больше не пропадают.
Чтобы изменить файл на GitHub: откройте config.js -> значок карандаша -> правка -> Commit changes.

## Уровни лояльности
levels:[[0,'Новичок',0],[3,'Постоянный клиент',0.05],[7,'VIP',0.1]] означает: с 3 заказов скидка 5%, с 7 заказов скидка 10%.
Скидка применяется к цене автоматически (если введён промокод, берётся большая из двух). Скидка 0 отключает её.

## Вход и регистрация (Supabase)
Пока в config.js не вписаны url и key, блок входа скрыт.
1. supabase.com -> New project.
2. SQL Editor -> New query -> вставьте supabase.sql -> Run.
3. Data API: Project URL (только https://xxxx.supabase.co, без пути). API Keys: Publishable key (sb_publishable_...).
4. Впишите их в config.js: sb:{url:'...',key:'...'}.
5. Authentication -> URL Configuration: Site URL = адрес вашего сайта.
Заказы вошедших клиентов видны вам в Supabase: Table Editor -> orders.
