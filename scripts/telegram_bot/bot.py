import os
import yaml
from telegram import Update
from telegram.ext import Application, CommandHandler, MessageHandler, filters, ContextTypes


class Bill:
    def __init__(self, name: str, amount: float, note: str):
        self.name = name
        self.amount = float(amount)
        self.note = note

    def to_dict(self):
        return {"name": self.name, "amount": self.amount, "note": self.note}


class BillHandler:
    def __init__(self, filename="bills.yaml"):
        self.bills = []
        self.state = {}  # user_id -> stage
        self.temp = {}   # user_id -> temp bill data
        self.filename = filename
        self.active_users = set()  # Tracks which users have activated the bot

    async def respond(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        user_id = update.effective_user.id
        text = update.message.text.strip().lower()

        # Activate bot only if user sends "bot"
        if user_id not in self.active_users:
            if text == "bot":
                self.active_users.add(user_id)
                self.state[user_id] = "await_name"
                self.temp[user_id] = {}
                await update.message.reply_text("BOT activated!('help' for usecases) Was dein Name Bro?:")
            else:
                return
            return

        if text == "botyaml":
            await self.show_yaml(update)
            return

        if text == "help":
            await update.message.reply_text(
                "BotRechnungen = Eingabe für neue Rechnungen\n"
                "Botyaml = Schickt das aktuelle YAML Dokument in dem die Rechnungen stehen\n"
                "Type 'stop' to deactivate the bot."
            )
            return

        if text == "stop":
            if user_id in self.active_users:
                self.active_users.remove(user_id)
            self.save_to_yaml()
            await update.message.reply_text("Bot deactivated. Bills saved to YAML.")
            return

        stage = self.state.get(user_id, "await_name")

        if stage == "await_name":
            self.temp[user_id]["name"] = text
            self.state[user_id] = "await_amount"
            await update.message.reply_text("Enter the bill amount:")
        elif stage == "await_amount":
            try:
                self.temp[user_id]["amount"] = float(text)
            except ValueError:
                await update.message.reply_text("Please enter a valid number.")
                return
            self.state[user_id] = "await_note"
            await update.message.reply_text("Enter a note/comment for this bill:")
        elif stage == "await_note":
            self.temp[user_id]["note"] = text
            bill = Bill(**self.temp[user_id])
            self.bills.append(bill)
            await update.message.reply_text(f"Bill recorded: {bill.to_dict()}")
            self.state[user_id] = "await_name"
            self.temp[user_id] = {}
            await update.message.reply_text("Enter the name for the next bill:")

    def save_to_yaml(self):
        with open(self.filename, "w") as f:
            yaml.dump([b.to_dict() for b in self.bills], f)

    async def show_yaml(self, update: Update):
        if os.path.exists(self.filename):
            with open(self.filename, "rb") as f:
                await update.message.reply_document(document=f)
        else:
            await update.message.reply_text("No YAML file found yet.")



def main():
    token = #<HIER KOMMT DER TELEGRAMM TOKEN> ODER HALT VERLINKEN

    app = Application.builder().token(token).build()
    bill_handler = BillHandler()

    # Start command
    async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
        await update.message.reply_text(
            "Hello! I'm alive!\n"
            "Type 'bot' to activate me and start entering bills.\n"
            "Type 'help' for help."
        )

    app.add_handler(CommandHandler("start", start))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, bill_handler.respond))

    try:
        print("Bot started...")
        app.run_polling()
    finally:
        bill_handler.save_to_yaml()
        print(f"Bills saved to {bill_handler.filename}")


if __name__ == "__main__":
    main()
