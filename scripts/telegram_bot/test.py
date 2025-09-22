from telegram import Update
import yaml
from telegram.ext import Application, CommandHandler, MessageHandler, filters, ContextTypes

checked_input = {"BotRechnung", "BotYAML", "Bothilfe"}

def process_input (text):
    if text not in checked_input:
        return
    elif text == "BotRechnung":
        return
    elif text == "BotYAML":
        return
    elif text == "Bothilfe":  
        print ("BotRechnungen = Eingabe für neue Rechnungen")
        print ("BotYAML = Schickt das aktuelle yaml Dokument in dem die Rechnungen stehen")

class Bot:
    async def respond(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        user_id = update.effective_user.id
        text = update.message.text.strip()


def main():
    user_input = input("Enter command: ").strip()
    process_input(user_input)
    
if __name__ == "__main__":
    main()