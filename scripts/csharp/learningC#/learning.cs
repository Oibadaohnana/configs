using System;
using System.Reflection.Metadata;
using System.Security.Cryptography.X509Certificates;
namespace Learning
{
    class Numberguessing
    {
        public static void Main(string[] args)
        {
            Console.WriteLine("Number guessing Game: ");
            Console.WriteLine("Number is between 0-10");

            int answer = 2;

            int guess;
            string guessString;
 
            do
            {
                guessString = Console.ReadLine();

                Console.WriteLine("You guessed: " + guessString);

                try
                {
                    guess = int.Parse(guessString);
                }
                catch (Exception e)
                {
                    Console.WriteLine("Not a Number!");
                    Console.WriteLine("Error Message:\n" + e);
                    return;
                }
                if (guess == answer)
                {
                    Console.WriteLine("you are correct!");
                }
                else if (guess < answer)
                {
                    Console.WriteLine("Incorrect! Number is larger ");
                }
                else if (guess > answer)
                {
                    Console.WriteLine("Incorrect! Number is smaller ");
                }

            }
            while (guess != answer);
        }
    }
}