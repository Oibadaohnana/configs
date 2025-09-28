using System;
namespace DodgeGame
{
    class DodgeGameMain
    {
        static void Main()
        {
            Unit playerUnit = new Unit();

            playerUnit.unitGraphic = "@";
            playerUnit.x = 10;
            playerUnit.y = 15;

            Console.SetCursorPosition(playerUnit.x,playerUnit.y);
            Console.Write(playerUnit.unitGraphic);

            Console.SetCursorPosition(
                0,
                Console.WindowHeight-1
            );
        }
    }
}

